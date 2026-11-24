//
//  SweepCoordinator.swift
//  一账 / Core / Persistence
//
//  职责：结算扫描的**落库**部分（架构 §5.1 的阶段 1 + 阶段 3）——
//  读候选 → 调 `SweepPlanner`（纯函数）→ 在 MainActor 一次 `save()` 原子提交。
//
//  为什么决策与落库必须拆开：
//  ① 决策是纯函数，错只会在单测里暴露，绝不产出脏数据（`SweepPlanner` 有 12+ 条无库单测）；
//  ② 落库必须在 MainActor 的唯一写 context（iOS 17 后台 context 写入后 `@Query` 不保证刷新，R6）；
//  ③ 事务边界：**一次 `save()` = 一个 SQLite 事务**，"账目插入 + 订阅日期推进"必须同生共死，
//     否则会出现"账写进去了但日期没推 → 下次扫描再写一遍"或"日期推了但账没写 → 漏账"。
//
//  失败处理（架构 §5.1 失败与部分成功表）：
//  - 阶段 1 读失败：整次扫描放弃，日期不推进，下次冷启动自然重试；
//  - 阶段 3 提交失败：整批 `rollback()`，然后**按订阅拆批重试一次**（每订阅一个事务），
//    保证一条坏数据不拖垮其余订阅；失败订阅记入 `failedSubscriptionIDs`，UI 给重试入口；
//  - 进程在提交前被杀：完全没有写入，日期未推进，下次补漏——天然幂等，无中间态。
//
//  刻意**不做**的事：
//  - 不在这里判断业务条件（那是 `SweepPlanner` 的活）；
//  - 不自己拼幂等键（唯一实现在 `SubscriptionSnapshot`，由 `SweepAction` 携带）；
//  - 不清理 `lastSweptCycleKey` 之外的状态；被删账抑制的周期由 `suppressedCycles` 负责（T14）。
//

import Foundation
import SwiftData

// MARK: - 错误

/// 结算扫描落库期可能遇到的、需要按订阅归因的错误。
enum SweepError: LocalizedError, Equatable {
    /// 订阅没有分类，且「订阅服务」预置分类也不存在
    case missingCategory(subscriptionID: UUID)
    /// 订阅没有账户，且没有任何可用账户
    case missingAccount(subscriptionID: UUID)

    var errorDescription: String? {
        switch self {
        case .missingCategory:
            return "订阅缺少分类，这笔账暂时无法生成"
        case .missingAccount:
            return "订阅缺少扣费账户，这笔账暂时无法生成"
        }
    }
}

/// 一次结算扫描的结果（日志、自检与 UI 提示共用）。
struct SweepReport: Hashable, Sendable {

    /// 新生成的账目数。
    var inserted: Int = 0
    /// 因幂等键已存在而跳过的期数（正常现象：上次扫描成功但进程被杀等）。
    var skipped: Int = 0
    /// 被推进了下次扣费日的订阅数（有账目生成 / 仅推进日期都算）。
    var advancedSubscriptionCount: Int = 0
    /// 命中 24 笔上限的订阅（UI 打标「订阅周期异常，请检查下次扣费日」）。
    var truncatedSubscriptionIDs: [UUID] = []
    /// 待续费提示（`autoRenew == false` 且已到期，R-SUB-6）。
    var notices: [RenewalNotice] = []
    /// 落库失败、需要 UI 给重试入口的订阅。
    var failedSubscriptionIDs: [UUID] = []
    /// 整次扫描耗时（毫秒）。架构给的预算是 15–40ms。
    var durationMilliseconds: Int = 0

    /// 什么都没发生（可以直接跳过任何 UI 提示）。
    var isEmpty: Bool {
        inserted == 0 && skipped == 0 && notices.isEmpty
            && truncatedSubscriptionIDs.isEmpty && failedSubscriptionIDs.isEmpty
    }

    /// 是否命中过 24 笔上限。
    var isTruncated: Bool { !truncatedSubscriptionIDs.isEmpty }

    /// 是否有订阅落库失败。
    var hasFailures: Bool { !failedSubscriptionIDs.isEmpty }
}

// MARK: - 协调器

/// 结算扫描协调器。
@MainActor
final class SweepCoordinator {

    /// 触发节流窗口（架构 §5.1：同名触发点在 60s 内只跑一次）。
    ///
    /// 只作用于"自动触发"（scenePhase / 进入 Tab）；用户显式下拉刷新用 `force: true` 绕过。
    static let minimumInterval: TimeInterval = 60

    /// 单次扫描最多生成多少笔（R-SUB-5）。
    static let entryLimit = SweepPlanner.defaultLimit

    /// 按订阅分组后的待写入单元。
    private struct PreparedSubscription {
        let subscription: Subscription
        let drafts: [EntryDraft]
        /// 该订阅最后一期的下期扣费日（由最后一条 action 携带）。
        let nextBillingDay: Int32
        /// 该订阅本期处理到的周期键（写入 `lastSweptCycleKey`，便于排查）。
        let lastCycleKey: String?
    }

    private let writer: LedgerWriter

    /// 上次实际执行扫描的时刻（节流用）。
    private var lastRunAt: Date?

    /// 重入保护：同一时刻只允许一次扫描。
    private var isRunning = false

    /// 提交成功后的回调（由 `AppEnvironment` 接到 `bumpDataVersion()`）。
    var onDidCommit: (() -> Void)?

    init(writer: LedgerWriter, onDidCommit: (() -> Void)? = nil) {
        self.writer = writer
        self.onDidCommit = onDidCommit
    }

    // MARK: - 入口

    /// 执行一次结算扫描。
    ///
    /// - Parameters:
    ///   - today: 今天（设备本地自然日；测试注入固定日）。
    ///   - force: 是否绕过 60s 节流（下拉刷新等显式意图传 `true`）。
    /// - Returns: 扫描结果。**不抛错**：扫描失败不该弹窗打断用户，失败信息在 `report` 里。
    @discardableResult
    func sweep(today: DateOnly = DateOnly(Date()), force: Bool = false) -> SweepReport {
        let startedAt = Date()
        var report = SweepReport()

        guard !isRunning, today.key > 0 else { return report }
        if !force, let lastRunAt, Date().timeIntervalSince(lastRunAt) < SweepCoordinator.minimumInterval {
            return report
        }
        isRunning = true
        defer { isRunning = false }

        do {
            let candidates = try writer.fetch(
                QueryDescriptors.subscriptionScanCandidates(onOrBefore: today)
            )
            guard !candidates.isEmpty else {
                lastRunAt = Date()
                return report
            }

            let snapshots = SubscriptionMapper.snapshots(candidates)
            let existingKeys = try existingUniqueKeys()
            let plan = SweepPlanner.plan(
                snapshots: snapshots,
                today: today,
                existingKeys: existingKeys,
                limit: SweepCoordinator.entryLimit
            )

            report.notices = plan.notices
            report.truncatedSubscriptionIDs = plan.truncatedSubscriptionIDs
            report.skipped = plan.skippedDuplicateCount

            guard !plan.actions.isEmpty || !plan.advances.isEmpty else {
                lastRunAt = Date()
                report.durationMilliseconds = SweepCoordinator.elapsedMilliseconds(since: startedAt)
                return report
            }

            // 阶段 2.5：把"缺分类/缺账户"这类**会在写库前暴露**的问题提前判定掉，
            // 避免它们在半途抛错、把整批其它订阅的写入一起回滚。
            let preparation = try prepare(plan: plan, candidates: candidates)
            report.failedSubscriptionIDs = preparation.failedSubscriptionIDs

            // 阶段 3：单事务提交
            do {
                let outcome = try applyBatch(preparation.prepared, advances: plan.advances)
                report.inserted = outcome.inserted
                report.skipped = plan.skippedDuplicateCount + outcome.skipped
                report.advancedSubscriptionCount = outcome.advanced
            } catch {
                // 整批回滚 → 按订阅拆批重试一次
                writer.rollback()
                retryPerSubscription(
                    preparation.prepared,
                    advances: plan.advances,
                    report: &report
                )
            }

            lastRunAt = Date()
            if report.inserted > 0 || report.advancedSubscriptionCount > 0 {
                onDidCommit?()
            }
        } catch {
            // 阶段 1 读失败：整次放弃，日期不推进，下次自然重试
            writer.rollback()
            report.durationMilliseconds = SweepCoordinator.elapsedMilliseconds(since: startedAt)
            return report
        }

        report.durationMilliseconds = SweepCoordinator.elapsedMilliseconds(since: startedAt)
        return report
    }

    /// 距上次成功扫描是否已超过节流窗口（UI 判断"进 Tab 要不要扫"用）。
    func shouldRun(now: Date = Date()) -> Bool {
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= SweepCoordinator.minimumInterval
    }

    // MARK: - 阶段 2.5：组装草稿

    /// 把计划拆成"按订阅分组、可直接落库"的单元。
    ///
    /// 分类 / 账户的兜底在这里做（订阅关系被置空时仍要能记账）：
    /// ① 订阅自己的分类 → ②「订阅服务」预置分类 → ③ 任一未隐藏支出分类；
    /// 账户：① 订阅自己的账户 → ② 任一未归档账户。
    /// 都找不到 → 该订阅记录为失败，**不推进日期**（推进了就等于永久跳过这一期，等于漏账）。
    private func prepare(
        plan: SweepPlan,
        candidates: [Subscription]
    ) throws -> (prepared: [PreparedSubscription], failedSubscriptionIDs: [UUID]) {

        var lookup: [UUID: Subscription] = [:]
        for candidate in candidates {
            lookup[candidate.id] = candidate
        }

        var order: [UUID] = []
        var grouped: [UUID: [SweepAction]] = [:]
        for action in plan.actions {
            if grouped[action.subscriptionID] == nil {
                order.append(action.subscriptionID)
            }
            grouped[action.subscriptionID, default: []].append(action)
        }

        var prepared: [PreparedSubscription] = []
        var failed: [UUID] = []

        for subscriptionID in order {
            guard let subscription = lookup[subscriptionID],
                  let actions = grouped[subscriptionID],
                  let lastAction = actions.last else {
                continue
            }

            var drafts: [EntryDraft] = []
            var resolved = true
            for action in actions {
                do {
                    drafts.append(try resolvedDraft(action.draft, subscriptionID: subscriptionID))
                } catch {
                    resolved = false
                    break
                }
            }

            guard resolved else {
                failed.append(subscriptionID)
                continue
            }

            prepared.append(
                PreparedSubscription(
                    subscription: subscription,
                    drafts: drafts,
                    nextBillingDay: lastAction.nextBillingDayAfter,
                    lastCycleKey: lastAction.cycleKey
                )
            )
        }

        return (prepared, failed)
    }

    /// 补齐草稿的分类 / 账户，并在缺失时抛错。
    private func resolvedDraft(_ draft: EntryDraft, subscriptionID: UUID) throws -> EntryDraft {
        var prepared = draft

        // 分类：订阅自带的 → 「订阅服务」预置分类
        var category: Category?
        if let categoryID = prepared.categoryID {
            category = try writer.category(id: categoryID)
        }
        if category == nil {
            category = try writer.category(id: PresetCatalog.subscriptionCategoryID)
        }
        guard let resolvedCategory = category else {
            throw SweepError.missingCategory(subscriptionID: subscriptionID)
        }
        prepared.categoryID = resolvedCategory.id

        // 账户：订阅自带的 → 第一个未归档账户
        var account: Account?
        if let accountID = prepared.accountID {
            account = try writer.account(id: accountID)
        }
        if account == nil {
            account = try writer.fetch(
                QueryDescriptors.accounts(includeArchived: false)
            ).first
        }
        guard let resolvedAccount = account else {
            throw SweepError.missingAccount(subscriptionID: subscriptionID)
        }
        prepared.accountID = resolvedAccount.id

        return prepared
    }

    // MARK: - 阶段 3：提交

    /// 一批写入（**不含** `save()` 之外的任何副作用）。
    ///
    /// - Parameters:
    ///   - items: 按订阅分组的账目草稿。
    ///   - advances: 只推进日期、不生成账目的订阅。
    /// - Returns: 计数。
    private func applyBatch(
        _ items: [PreparedSubscription],
        advances: [SubscriptionAdvance]
    ) throws -> (inserted: Int, skipped: Int, advanced: Int) {
        var inserted = 0
        var skipped = 0
        /// **按订阅去重**：一个订阅可能同时有账目（携带 nextBillingDayAfter）和一条
        /// 补尾的 advance（见 `SweepPlanner` 末尾注释）。这个字段的语义是
        /// "被推进了下次扣费日的订阅数"，不是"执行了几次推进"。
        var advancedSubscriptionIDs = Set<UUID>()
        let now = Date()

        for item in items {
            for draft in item.drafts {
                let outcome = try writer.insert(draft, save: false)
                if outcome.wasInserted {
                    inserted += 1
                } else {
                    skipped += 1
                }
            }
            try writer.update(item.subscription, save: false) { model in
                model.nextBillingDay = item.nextBillingDay
                if let lastCycleKey = item.lastCycleKey {
                    model.lastSweptCycleKey = lastCycleKey
                }
                model.updatedAt = now
            }
            advancedSubscriptionIDs.insert(item.subscription.id)
        }

        for advance in advances {
            guard let subscription = try writer.subscription(id: advance.subscriptionID) else {
                continue
            }
            try writer.update(subscription, save: false) { model in
                model.nextBillingDay = advance.nextBillingDay
                if let lastCycleKey = advance.lastCycleKey {
                    model.lastSweptCycleKey = lastCycleKey
                }
                model.updatedAt = now
            }
            advancedSubscriptionIDs.insert(advance.subscriptionID)
        }

        let advanced = advancedSubscriptionIDs.count

        // 一次 save = 一个 SQLite 事务：账目 + 日期同生共死
        try writer.save()
        return (inserted, skipped, advanced)
    }

    /// 整批提交失败后的兜底：按订阅拆批重试（每批内部仍是一个事务）。
    private func retryPerSubscription(
        _ items: [PreparedSubscription],
        advances: [SubscriptionAdvance],
        report: inout SweepReport
    ) {
        for item in items {
            do {
                let outcome = try applyBatch([item], advances: [])
                report.inserted += outcome.inserted
                report.skipped += outcome.skipped
                report.advancedSubscriptionCount += outcome.advanced
            } catch {
                writer.rollback()
                report.failedSubscriptionIDs.append(item.subscription.id)
            }
        }

        for advance in advances {
            do {
                let outcome = try applyBatch([], advances: [advance])
                report.advancedSubscriptionCount += outcome.advanced
            } catch {
                writer.rollback()
                report.failedSubscriptionIDs.append(advance.subscriptionID)
            }
        }
    }

    // MARK: - 幂等键批量取数

    /// 已有订阅账目的幂等键集合（含软删记录，R-SUB-7）。
    private func existingUniqueKeys() throws -> Set<String> {
        let entries = try writer.fetch(QueryDescriptors.entries(ofSource: .subscription))
        var keys = Set<String>()
        for entry in entries {
            if let key = entry.sourceCycleUniqueKey, !key.isEmpty {
                keys.insert(key)
            }
        }
        return keys
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        Int((Date().timeIntervalSince(start) * 1_000).rounded())
    }
}
