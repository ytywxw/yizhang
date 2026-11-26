//
//  Diagnostics.swift
//  一账 / Core / Persistence
//
//  职责：启动自检与一致性守护（架构 §3.3 第 3 层，T05 落地 / T23 重构）。
//
//  ## 为什么必须拆成 detect / repair 两步
//
//  T05 的版本把"检查"和"自动修"写在一个函数里，后果是：
//  ① 想在测试里断言"能不能识别出脏数据"，会被顺带修掉，测不出识别能力；
//  ② 想在不改数据的前提下跑一次体检（Release 的唯一行为），没有入口；
//  ③ 修什么、修了几条，说不清楚——修复和检查混在同一个 200 行循环里。
//  拆开之后：`detect` 只读、无副作用、可在任何构建里跑；`repair` 显式接收 report，
//  只修"能被安全修"的那一类，并返回条数。
//
//  ## 五项检查
//
//  ① 重复 `sourceCycleUniqueKey`（**含软删除记录**，R-SUB-7 要求）；
//  ② 孤儿引用（非转账账目的 category / account 为 nil，等于无分类账目，违反 R-CAT-2）；
//  ③ 非法 `occurredDay`（0 或未来日期——A2 铁律是"自然日必须真实"）；
//  ④ 负金额（金额只允许 > 0）；
//  ⑤ 状态为 active 但 `nextBillingDay` 已经过去的订阅（D21 那一类：
//     扫描推进日期时漏了尾巴，用户会看到"到期日停在过去、却永远不生成账目"）。
//
//  ## 修复策略
//
//  **只修重复幂等键**（保留 `createdAt` 最早的一条，其余软删），且只在 DEBUG 调用。
//  其余四项只统计不改：它们要么是用户数据（孤儿引用、过期订阅日），
//  要么需要人来判断意图（非法日、负金额），静默改写比留痕危险得多。
//
//  性能预算（实测 iPhone 17 Pro 模拟器 / iOS 26.5，2026-11）：全表扫 ≈17-20µs/行 ——
//  2 000 行 ≈41ms（39.5-45.6ms），1 万行 ≈200ms（201.0 / 204.2ms 两轮）。
//
//  这笔钱里 **~85% 是 SwiftData 逐行 materialize**（2 000 行 ~35ms），与行数线性、
//  与缓存冷热无关 —— 同一个 context 连跑三次 fetch 都是 30-35ms，而空谓词 fetch 只要
//  0.3ms。我们自己的逐条扫（`scan`）2 000 行只要 2-6ms。
//
//  所以任何"全表扫 < 30ms"的说法都是错的（旧版本这里写的正是 30ms）。两条测试各守一层：
//  `testScanTwoThousandEntriesUnder30Milliseconds` 盯 `scan` 的复杂度，
//  `testDetectTwoThousandEntriesUnderCoarseBudget`（300ms）只防量级事故。
//

import Foundation
import SwiftData

/// 启动自检。
enum Diagnostics {

    /// 自检结果（一次 `detect` 的完整产出）。
    struct Report: Sendable {

        /// schema 里的模型数量（结构自检用）。
        var modelCount: Int = 0

        /// 重复幂等键 → 命中的账目 id（按 `createdAt` 升序，第一个是应当保留的）。
        ///
        /// **含软删除记录**（R-SUB-7 的口径）：同一个键被两条记录占着，即使其中一条已删，
        /// 也说明"这个周期被写重了"。
        var duplicateUniqueKeyEntries: [String: [UUID]] = [:]

        /// 其中**仍然有效**（未删除）的那些键。
        ///
        /// 为什么单独一份：修复手段是软删多余的那条，软删之后"键仍被两条记录引用"依旧成立，
        /// 但真正有害的只是"两条都有效"。健康判定必须看这一份，否则修完之后自检还是红的。
        var duplicateLiveEntries: [String: [UUID]] = [:]

        /// 孤儿引用条数（非转账账目的分类或账户为 nil）。
        var orphanReferenceCount: Int = 0

        /// 非法发生日条数（`occurredDay == 0` 或晚于今天）。
        var invalidDayCount: Int = 0

        /// 负金额条数。
        var negativeAmountCount: Int = 0

        /// 状态 active 但下次扣费日已过去的订阅 id（D21 类问题的探针）。
        var staleSubscriptionIDs: [UUID] = []

        /// 本次自动修复的条数（仅 DEBUG 且调用了 `repair` 时 > 0）。
        var repairedCount: Int = 0

        /// 自检耗时（毫秒）。
        var durationMilliseconds: Double = 0

        /// 重复幂等键 → 命中条数（由 `duplicateUniqueKeyEntries` 派生）。
        var duplicateUniqueKeyCounts: [String: Int] {
            duplicateUniqueKeyEntries.mapValues { $0.count }
        }

        /// 重复键命中的记录总数（日志用）。
        var duplicateEntryCount: Int {
            duplicateUniqueKeyEntries.values.reduce(0) { $0 + $1.count }
        }

        /// 是否健康：五项检查全部为 0（重复键按"仍有两条有效"算）。
        var isHealthy: Bool {
            duplicateLiveEntries.isEmpty
                && orphanReferenceCount == 0
                && invalidDayCount == 0
                && negativeAmountCount == 0
                && staleSubscriptionIDs.isEmpty
        }

        /// 是否存在"两条都有效"的重复（未修复的重复）。
        var unresolvedDuplicateCount: Int {
            duplicateLiveEntries.values.reduce(0) { $0 + $1.count }
        }

        init(
            modelCount: Int = 0,
            duplicateUniqueKeyEntries: [String: [UUID]] = [:],
            duplicateLiveEntries: [String: [UUID]] = [:],
            orphanReferenceCount: Int = 0,
            invalidDayCount: Int = 0,
            negativeAmountCount: Int = 0,
            staleSubscriptionIDs: [UUID] = [],
            repairedCount: Int = 0,
            durationMilliseconds: Double = 0
        ) {
            self.modelCount = modelCount
            self.duplicateUniqueKeyEntries = duplicateUniqueKeyEntries
            self.duplicateLiveEntries = duplicateLiveEntries
            self.orphanReferenceCount = orphanReferenceCount
            self.invalidDayCount = invalidDayCount
            self.negativeAmountCount = negativeAmountCount
            self.staleSubscriptionIDs = staleSubscriptionIDs
            self.repairedCount = repairedCount
            self.durationMilliseconds = durationMilliseconds
        }

        /// 一行日志。
        var summary: String {
            guard !isHealthy else {
                return "自检通过（\(modelCount) 个模型，\(String(format: "%.1f", durationMilliseconds))ms）"
            }
            return "自检发现异常：重复键 \(duplicateEntryCount) 条（其中 \(unresolvedDuplicateCount) 条仍有效） / 孤儿 \(orphanReferenceCount) 条 / "
                + "非法日 \(invalidDayCount) 条 / 负金额 \(negativeAmountCount) 条 / "
                + "过期订阅日 \(staleSubscriptionIDs.count) 条（已修复 \(repairedCount) 条）"
        }
    }

    // MARK: - 逐条扫的输入 / 输出（值类型投影）

    /// `detect` 逐条扫用到的字段投影。
    ///
    /// 存在的唯一理由：`detect` 的耗时被 SwiftData 的逐行 materialize 淹掉了
    /// （2 000 行约 35ms，≈17µs/行，与行数线性、与缓存冷热无关），
    /// 想在测试里盯「我们自己写的那部分逻辑有没有退化」就必须能脱离 context 跑。
    ///
    /// 关系字段在这里被压成 `hasCategory` / `hasAccount` 两个 `Bool` ——
    /// fault 就发生在构造这个投影的那一刻（`entry.category != nil`），
    /// 总代价与原先在循环里懒访问完全一致，只是把"读库"和"算"分成了两步。
    struct EntrySnapshot: Sendable {
        var id: UUID
        var sourceCycleUniqueKey: String?
        var deletedAt: Date?
        var createdAt: Date
        var isTransfer: Bool
        var hasCategory: Bool
        var hasAccount: Bool
        var occurredDay: Int32
        var amount: Int64
    }

    /// 逐条扫描的结果（①①b②③④ 的产出，不含 ⑤ 订阅）。
    struct ScanResult: Sendable {
        var duplicateUniqueKeyEntries: [String: [UUID]] = [:]
        var duplicateLiveEntries: [String: [UUID]] = [:]
        var orphanReferenceCount: Int = 0
        var invalidDayCount: Int = 0
        var negativeAmountCount: Int = 0
    }

    // MARK: - 入口

    /// 完整自检 + （DEBUG）自动修。**Release 只检测不修改**。
    ///
    /// - Parameter container: 应用容器（自检自己建 context，不干扰主写入上下文）。
    @discardableResult
    @MainActor
    static func run(in container: ModelContainer) throws -> Report {
        try run(in: ModelContext(container))
    }

    /// 完整自检 + （DEBUG）自动修（可注入 context）。
    @discardableResult
    @MainActor
    static func run(in context: ModelContext) throws -> Report {
        var report = try detect(in: context)
        #if DEBUG
        let repaired = try repair(in: context, report: report)
        report.repairedCount = repaired
        #endif
        return report
    }

    // MARK: - 检测（纯读，无副作用）

    /// 只检测，**绝不修改任何数据**。
    ///
    /// 这是 Release 构建里唯一会跑的那一半：发现问题只落日志，
    /// 让"用户数据被 App 悄悄改掉"这种事在发布版里不可能发生。
    ///
    /// - Parameter context: 待检查的上下文。
    /// - Returns: 检测报告。
    @MainActor
    static func detect(in context: ModelContext) throws -> Report {
        let started = Date()
        let today = DateOnly(Date())

        let entries = try context.fetch(QueryDescriptors.allEntries())
        let subscriptions = try context.fetch(QueryDescriptors.allSubscriptions())

        // ①①b②③④ 全部在 `scan` 里做。这里先投影：**fault 只在这一步发生**，
        // 之后就是纯值类型运算，可脱离 context 单独测（见 `ScanResult` 的说明）。
        let snapshots = entries.map(EntrySnapshot.init)
        let scanned = scan(snapshots, today: today)

        // ⑤ 状态 active、有下次扣费日、却停在过去的订阅
        //    （D21：扫描推进日期时漏了尾巴，用户会永远收不到新账目）
        //    没有搬进 `scan`：它查的是另一张表，跟逐条扫的代价无关。
        let staleSubscriptionIDs = subscriptions
            .filter { $0.status == .active && $0.nextBillingDay > 0 && $0.nextBillingDay < today.key }
            .map(\.id)

        return Report(
            // V1.1：容器已迁到 `SchemaV2`（7 个模型，含 `EntryTemplate`），自检口径必须跟着走，
            // 否则报告里的模型数会永远停在 6，结构自检形同虚设。
            modelCount: SchemaV2.models.count,
            duplicateUniqueKeyEntries: scanned.duplicateUniqueKeyEntries,
            duplicateLiveEntries: scanned.duplicateLiveEntries,
            orphanReferenceCount: scanned.orphanReferenceCount,
            invalidDayCount: scanned.invalidDayCount,
            negativeAmountCount: scanned.negativeAmountCount,
            staleSubscriptionIDs: staleSubscriptionIDs,
            durationMilliseconds: Date().timeIntervalSince(started) * 1_000
        )
    }

    // MARK: - 逐条扫（纯函数，可脱离 ModelContext 测）

    /// ①①b②③④ 五项检查的全部逻辑。
    ///
    /// **纯函数**：不碰 `ModelContext`、不读写任何 `@Model`，只吃值类型。
    /// 拆出来的目的不是复用，是**可测** —— 原先这几十行和 `fetch` 粘在同一个函数里，
    /// 想量它的耗时，量到的 95% 是 SwiftData 逐行 materialize 的成本（≈17µs/行）。
    ///
    /// - Parameters:
    ///   - snapshots: 账目的字段投影，顺序即为 `allEntries()` 的顺序。
    ///   - today: "今天"，用于判非法日（未来日期）。
    /// - Returns: 四项计数的汇总（第五项订阅不在本函数职责内）。
    static func scan(_ snapshots: [EntrySnapshot], today: DateOnly) -> ScanResult {
        var result = ScanResult()

        // ① 重复幂等键：按 createdAt 升序分组，第一条保留
        var grouped: [String: [EntrySnapshot]] = [:]
        for snapshot in snapshots {
            guard let key = snapshot.sourceCycleUniqueKey, !key.isEmpty else { continue }
            grouped[key, default: []].append(snapshot)
        }
        for (key, bucket) in grouped where bucket.count > 1 {
            let ordered = bucket.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            result.duplicateUniqueKeyEntries[key] = ordered.map(\.id)
        }

        // ①b 同一批里"仍然有效"的重复（修复只可能消掉这一种）
        //     id 数组保持 `snapshots` 的原始顺序 —— 这一份只用于"有哪些键重了"，
        //     与①的"谁该保留"无关，别顺手给它加排序。
        var liveGrouped: [String: [UUID]] = [:]
        for snapshot in snapshots {
            guard let key = snapshot.sourceCycleUniqueKey, !key.isEmpty, snapshot.deletedAt == nil else {
                continue
            }
            liveGrouped[key, default: []].append(snapshot.id)
        }
        result.duplicateLiveEntries = liveGrouped.filter { $0.value.count > 1 }

        // ②③④ 逐条检查
        for snapshot in snapshots {
            // 转账没有分类是设计使然（PRD 3.2.1），不算孤儿
            if !snapshot.isTransfer, !snapshot.hasCategory || !snapshot.hasAccount {
                result.orphanReferenceCount += 1
            }
            if snapshot.occurredDay == 0 || snapshot.occurredDay > today.key {
                result.invalidDayCount += 1
            }
            if snapshot.amount < 0 {
                result.negativeAmountCount += 1
            }
        }

        return result
    }

    // MARK: - 修复（显式、可测、只在 DEBUG 被 `run` 调用）

    /// 按报告修可安全修的问题：**只处理重复幂等键**。
    ///
    /// 为什么只修这一项：重复键一定是程序 bug 的产物（同一期被写了两笔），
    /// 保留最早一条、其余软删是唯一说得通的处理；而孤儿引用 / 过期订阅日 / 非法日 /
    /// 负金额都可能是用户真实意图或需要人判断的数据，自动改会把"可排查的异常"
    /// 变成"无法解释的数值"。
    ///
    /// - Parameters:
    ///   - context: 写入上下文。
    ///   - report: `detect(in:)` 的结果（本方法只信这份报告，不重新扫）。
    /// - Returns: 实际软删的条数。
    @discardableResult
    @MainActor
    static func repair(in context: ModelContext, report: Report) throws -> Int {
        guard !report.duplicateUniqueKeyEntries.isEmpty else { return 0 }

        // 报告里存的是 id 而不是模型对象：report 要能跨上下文 / 跨线程传递，
        // 持有一堆 `@Model` 会把 context 一起钉住。
        var uniqueStaleIDs = Set<UUID>()
        for ids in report.duplicateUniqueKeyEntries.values {
            for id in ids.dropFirst() { uniqueStaleIDs.insert(id) }
        }

        var repaired = 0
        let now = Date()
        // 复用 `LedgerWriter` 的软删除唯一入口（V1.1 风险 R1）：`deletedAt` 与 `deletedDay`
        // 两列必须同进同出。这里有 `ModelContext` 但不持有主写入器，因此就地造一个
        // "只带 context 的 writer" —— 它不新增事务边界，只是把两列的写入收敛回同一段代码。
        let writer = LedgerWriter(context: context)
        for id in uniqueStaleIDs {
            guard let entry = try? context.fetch(
                FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.id == id })
            ).first else { continue }
            // 已经软删的不重复计数
            guard entry.deletedAt == nil else { continue }
            try writer.markDeleted(entry, at: now)
            repaired += 1
        }

        if repaired > 0 {
            try context.save()
        }
        return repaired
    }

    // MARK: - 单项检查（供测试与局部排查复用）

    /// 找出 `sourceCycleUniqueKey` 重复的账目。
    ///
    /// 语义要点：**包含软删除记录**（R-SUB-7 要求"含软删除记录"唯一）。
    /// 不用 `#Predicate` 过滤可选字符串（iOS 17 不稳），而账目总量 ≤1 万行，全表扫代价可忽略。
    ///
    /// - Parameter context: 待检查的上下文。
    /// - Returns: 重复键 → 账目 id 列表（按 `createdAt` 升序，第一个即应保留者）。
    @MainActor
    static func duplicateUniqueKeys(in context: ModelContext) throws -> [String: [UUID]] {
        try detect(in: context).duplicateUniqueKeyEntries
    }

    /// 结构自检：回报 schema 里的模型数量（验证 V1.1 的七个模型都注册进 `SchemaV2`）。
    ///
    /// - Parameter schema: 待检查的 schema。
    static func check(schema: Schema) -> Report {
        Report(modelCount: schema.entities.count)
    }

    /// 数据自检（改走 `detect`，**不含自动修复**，供测试断言"识别能力"）。
    @MainActor
    static func check(container: ModelContainer) throws -> Report {
        try detect(in: ModelContext(container))
    }
}

// MARK: - 从 @Model 构造投影

extension Diagnostics.EntrySnapshot {

    /// 从一条账目拍下投影。
    ///
    /// 放在 extension 里而不是结构体体内，是为了**保住编译器合成的逐成员初始化器** ——
    /// 测试要能直接构造投影而不碰 SwiftData，那就是它存在的意义。
    ///
    /// `entry.category` / `entry.account` 的 fault 发生在这一行；与原先在检查循环里
    /// 懒访问相比，总代价一样，只是时机提前了（fetch → 投影 → 纯计算）。
    init(_ entry: LedgerEntry) {
        self.init(
            id: entry.id,
            sourceCycleUniqueKey: entry.sourceCycleUniqueKey,
            deletedAt: entry.deletedAt,
            createdAt: entry.createdAt,
            isTransfer: entry.isTransfer,
            hasCategory: entry.category != nil,
            hasAccount: entry.account != nil,
            occurredDay: entry.occurredDay,
            amount: entry.amount
        )
    }
}
