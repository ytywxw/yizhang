//
//  LedgerService.swift
//  一账 / Core / Services
//
//  职责：记账用例层——"一个用户动作 = 一个方法"（架构 §5.3）。
//
//  分层位置：`View → ViewModel → LedgerService → LedgerWriter/QueryDescriptors → SwiftData`。
//  本层允许 `import SwiftData`（要引用 `@Model` 类型），**禁止 `import SwiftUI`**，
//  也禁止自己调 `context.save()`——提交一律经 `LedgerWriter`。
//
//  本类承担两类责任：
//  ① **业务校验**（金额 > 0、支出必须有分类、转账不能转给自己、发生日不能是未来）；
//  ② **幂等键补齐**（待办 → `todo|<id>`、订阅 → `<subID>|<cycleKey>`）。
//     拼接实现只在 `SubscriptionSnapshot.makeUniqueKey`，本类不重复写字符串模板。
//
//  本批不做（后续任务）：
//  - 订阅账目删除的双分支 A/B（R-SUB-DEL，T14）；
//  - 结算扫描（T11）；
//  - 待办完成后的记账（T15，走同一套 `create`）。
//

import Foundation
import SwiftData

// MARK: - 错误

/// 记账相关的业务错误。全部带中文 `errorDescription`，UI 可直接展示。
enum LedgerError: LocalizedError, Equatable {
    /// 金额必须 > 0（R-IN-1）
    case amountNotPositive
    /// 非转账账目必须有分类（R-IN-2 / R-CAT-2：不允许无分类账目）
    case missingCategory
    /// 必须有账户
    case missingAccount
    /// 转账的转出与转入不能是同一账户
    case sameTransferAccount
    /// 转账必须有转入账户
    case missingTransferTarget
    /// 不允许未来日期（PRD 3.2.1）
    case futureDate
    /// 发生日非法（0 或不是真实日期）
    case invalidDate
    /// 备注超长（PRD：≤ 100 字）
    case noteTooLong
    /// 目标账目不存在（可能已被删除）
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .amountNotPositive: return "金额需要大于 0"
        case .missingCategory: return "请选择一个分类"
        case .missingAccount: return "请选择一个账户"
        case .sameTransferAccount: return "转出和转入不能是同一个账户"
        case .missingTransferTarget: return "请选择转入账户"
        case .futureDate: return "不能记到未来的日期"
        case .invalidDate: return "发生日期无效"
        case .noteTooLong: return "备注最多 100 字"
        case .entryNotFound: return "这笔账已不存在"
        }
    }
}

// MARK: - 值类型

/// 月度汇总。
struct MonthSummary: Hashable, Sendable {
    /// 支出合计（正数）。
    let expense: Money
    /// 收入合计（正数）。
    let income: Money

    /// 结余 = 收入 - 支出（可能为负）。
    var balance: Money { income - expense }

    var isEmpty: Bool { expense.isZero && income.isZero }

    static let zero = MonthSummary(expense: .zero, income: .zero)

    init(expense: Money, income: Money) {
        self.expense = expense
        self.income = income
    }
}

/// 可撤销的删除凭据（R-EDIT-3，3 秒撤销）。
///
/// 携带**删除前的全字段快照**：撤销时把快照整体写回，因此"含 sourceCycleKey 等所有字段"
/// 的完整性不依赖"软删只改两列"这个实现细节。
struct UndoToken: Hashable, Sendable {
    let entryID: UUID
    /// 删除发生时刻（用于校验"撤销的仍是同一次删除"）。
    let deletedAt: Date
    let snapshot: LedgerEntrySnapshot
}

/// 编辑账目时的可变字段集合（`nil` = 不改）。
///
/// **刻意不包含 `sourceRaw` / `sourceRefID` / `sourceCycleKey`**：
/// R-EDIT-1/2 规定账目 → 源对象是单向的，编辑不得改写来源，
/// 因此不是"运行时校验"，而是**类型上根本表达不出来**。
struct EntryChanges: Hashable, Sendable {
    var type: EntryType?
    var amount: Int64?
    var occurredDay: Int32?
    var categoryID: UUID?
    var accountID: UUID?
    var toAccountID: UUID?
    var note: String?

    init(
        type: EntryType? = nil,
        amount: Int64? = nil,
        occurredDay: Int32? = nil,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        toAccountID: UUID? = nil,
        note: String? = nil
    ) {
        self.type = type
        self.amount = amount
        self.occurredDay = occurredDay
        self.categoryID = categoryID
        self.accountID = accountID
        self.toAccountID = toAccountID
        self.note = note
    }
}

// MARK: - 服务

/// 记账服务：手动记账、待办记账、订阅记账共用同一个 `create`。
@MainActor
final class LedgerService {

    /// 备注长度上限（PRD 3.2.1）。
    static let noteLimit = 100

    private let writer: LedgerWriter

    /// 写入提交后的回调（由 `AppEnvironment` 接到 `bumpDataVersion()`）。
    ///
    /// 用回调而不是让 Service 反向持有 `AppEnvironment`：避免循环引用，
    /// 也让 Service 可以在测试里独立构造（回调留空即可）。
    var onDidCommit: (() -> Void)?

    /// **软删之后**的清理钩子（V1.1，由 `AppEnvironment` 接到 `TrashService.purgeExpired`）。
    ///
    /// 为什么是闭包而不是注入 `TrashService`：`TrashService` 已经强依赖
    /// `SubscriptionService`（恢复时要 `unsuppress`），如果各 Service 再反向强引用
    /// `TrashService`，对象图里就出现环（ARC 下不会崩，但两边都永远不释放）。
    /// 闭包把依赖方向固定成单向，本类也不必知道"回收站"这个概念。
    ///
    /// 调用时机是**提交之后**，不是提交之前：清理要删的是"已经软删满 30 天"的记录，
    /// 它必须先看到刚刚这次软删已经落库。钩子内部自行 `try?`，本类不关心成败——
    /// 清理失败最多让过期项多留一会儿，绝不能因此把用户的删除动作回滚掉。
    var onDidSoftDelete: (() -> Void)?

    /// "今天"的来源（`validateDay` 用它判断未来日期）。
    ///
    /// 为什么是闭包而不是一个存下来的 `DateOnly`：
    /// ① **可测试**——QA 不必为了让一条 2026 年的 fixture 过校验，把 500 条数据全改到 2025；
    /// ② **不僵硬**——App 里这个 service 是长期存活的，若在 `init` 里把日期算死，
    ///    跨过午夜后"今天"就永远停在昨天，用户补录当天账目会被误判成未来日期。
    private let todayProvider: () -> DateOnly

    /// - Parameters:
    ///   - writer: 唯一写入口。
    ///   - today: 固定的"今天"（测试注入）。`nil` = 每次校验时读系统时钟。
    ///   - onDidCommit: 提交后的回调。
    init(
        writer: LedgerWriter,
        today: DateOnly? = nil,
        onDidCommit: (() -> Void)? = nil
    ) {
        self.writer = writer
        self.todayProvider = today.map { fixed in { fixed } } ?? { DateOnly(Date()) }
        self.onDidCommit = onDidCommit
    }

    // MARK: - 创建

    /// 创建一笔账目（手动 / 待办 / 订阅共用）。
    ///
    /// 校验全部集中在业务层，`LedgerWriter` 不做任何业务判断。
    ///
    /// - Parameters:
    ///   - draft: 账目草稿。
    ///   - save: 是否立即提交。默认 `true`（一个用户动作 = 一个事务）；
    ///     订阅补录（T10）与结算扫描（T11）传 `false`，把"多笔账目 + 订阅日期推进"
    ///     放进同一次 `save()`，失败时整批回滚不留中间态。
    ///     **`save == false` 时本方法不广播 `onDidCommit`**，由批量写入方在提交后自行广播。
    /// - Returns: `.inserted(id)` 或 `.skippedDuplicate(key)`（幂等命中，不是错误）。
    @discardableResult
    func create(_ draft: EntryDraft, save: Bool = true) throws -> InsertOutcome {
        let prepared = try validated(draft)
        let outcome = try writer.insert(prepared, save: save)

        if save {
            switch outcome {
            case .inserted:
                onDidCommit?()
            case .skippedDuplicate:
                // 幂等命中：不广播、不报错（重复扫描是正常现象）
                break
            }
        }
        return outcome
    }

    // MARK: - 编辑

    /// 修改一笔账目。**不改来源字段**（由 `EntryChanges` 的类型定义保证）。
    ///
    /// - Parameters:
    ///   - id: 账目 id。
    ///   - changes: 要改的字段。
    /// - Returns: 修改后的快照。
    @discardableResult
    func update(id: UUID, changing changes: EntryChanges) throws -> LedgerEntrySnapshot {
        guard let current = try writer.entry(id: id) else { throw LedgerError.entryNotFound }

        // 用"改完之后的样子"重新跑一遍校验，避免把一笔合法账目改成非法状态
        let mergedAmount = changes.amount ?? current.amount
        guard mergedAmount > 0 else { throw LedgerError.amountNotPositive }

        let mergedType = changes.type ?? current.type
        let mergedDay = changes.occurredDay ?? current.occurredDay
        try validateDay(mergedDay)

        let mergedNote = changes.note ?? current.note
        guard mergedNote.count <= LedgerService.noteLimit else { throw LedgerError.noteTooLong }

        let mergedCategoryID = changes.categoryID ?? current.category?.id
        if mergedType != .transfer, mergedCategoryID == nil { throw LedgerError.missingCategory }

        let mergedAccountID = changes.accountID ?? current.account?.id
        guard mergedAccountID != nil else { throw LedgerError.missingAccount }

        let mergedToAccountID = changes.toAccountID ?? current.toAccount?.id
        if mergedType == .transfer {
            guard let target = mergedToAccountID else { throw LedgerError.missingTransferTarget }
            guard target != mergedAccountID else { throw LedgerError.sameTransferAccount }
        }

        let snapshot = try writer.update(id: id) { entry in
            entry.typeRaw = mergedType.raw
            entry.amount = mergedAmount
            entry.occurredDay = mergedDay
            entry.note = mergedNote
            entry.category = try writer.category(id: mergedCategoryID)
            entry.account = try writer.account(id: mergedAccountID)
            entry.toAccount = mergedType == .transfer ? try writer.account(id: mergedToAccountID) : nil
        }

        guard let snapshot else { throw LedgerError.entryNotFound }
        onDidCommit?()
        return snapshot
    }

    // MARK: - 删除与撤销

    /// 软删除一笔账目（R-EDIT-3）。
    ///
    /// - Parameter id: 账目 id。
    /// - Returns: 可撤销凭据；账目不存在时返回 nil。
    func delete(id: UUID) async -> UndoToken? {
        let moment = Date()
        guard let snapshot = try? writer.softDelete(id: id, at: moment) else { return nil }
        onDidCommit?()
        // 软删之后的回收站清理（PRD 6.2 的第二个挂载点）。放在 `onDidCommit` 之后：
        // 先广播让界面看到"少了一笔"，再去清理过期的旧记录，两件事互不依赖。
        onDidSoftDelete?()
        return UndoToken(entryID: snapshot.id, deletedAt: moment, snapshot: snapshot)
    }

    /// 撤销软删除。凭据已失效（账目被硬删）时静默失败——撤销按钮不该报错弹窗。
    ///
    /// - Parameter token: `delete(id:)` 返回的凭据。
    /// - Returns: 是否恢复成功。
    @discardableResult
    func undoDelete(_ token: UndoToken) -> Bool {
        guard let restored = try? writer.restore(token.snapshot), restored else { return false }
        onDidCommit?()
        return true
    }

    /// 硬删除（**只允许订阅删账 B 分支使用**，R-SUB-DEL B）。
    ///
    /// 为什么必须硬删：幂等键在**含软删记录**的范围内唯一（R-SUB-7），
    /// 软删后那条记录仍然占着 `<subID>|<cycleKey>`，扫描永远跳过它，
    /// "删掉让订阅重新生成"就永远不成立（风险 R8）。
    ///
    /// - Parameter id: 账目 id。
    /// - Returns: 是否真的删掉了一条。
    @discardableResult
    func hardDelete(id: UUID) -> Bool {
        guard (try? writer.hardDelete(id: id)) == true else { return false }
        onDidCommit?()
        return true
    }

    // MARK: - 订阅删账

    // T14 会在这里加 `deleteSubscriptionEntry(_:mode:)`：
    // A 分支 = 软删 + 该周期写入 suppressedCycles（日期不回退）；
    // B 分支 = **硬删** + nextBillingDay 回退 + 锚定日重置（R8：B 分支软删会导致账目永不重生）。

    // MARK: - 待确认（V1.1 F-SUB-13）
    //
    // 只做"确认"这一侧。**"不是这笔"（否定）不在这里**：否定的实现需要软删 + 抑制订阅周期，
    // 而抑制周期意味着要持有 `SubscriptionService`，`LedgerService` 与 `SubscriptionService`
    // 之间已经存在 ledger → subscription 的构造关系（`SubscriptionService(writer:ledger:)`），
    // 反向注入就是环。所以否定放在 `SubscriptionService.denyEntry(id:)`。

    /// 确认某一笔待确认账目（`pending` → `confirmed`）。
    ///
    /// 三条刻意的行为：
    /// ① **只看状态，不做业务推断**：不是 pending 就返回 `false`，不报错、不写库、不广播。
    ///    幂等在这里不是"优化"而是语义——首页行动条上的"全部确认"与用户连点两次
    ///    都会重复调用同一个 id，第二次响一声"操作失败"是错的；
    /// ② **不改金额、不改任何其它字段**：用户点的是"这笔账是对的"，不是"以我说的为准"。
    ///    顺手刷新 `updatedAt`，让导出/同步能看出这一笔被核对过；
    /// ③ 只有真的写成功才广播 `onDidCommit`——空转广播会让首页列表无谓地重建。
    ///
    /// - Parameter id: 账目 id。
    /// - Returns: 是否真的从 pending 变成了 confirmed。
    @discardableResult
    func confirm(id: UUID) throws -> Bool {
        guard let entry = try writer.entry(id: id), entry.isPending else { return false }
        // 走 `writer.update(id:)` 而不是自己写 context：`updatedAt` 与 `save()` 由唯一写入口负责
        let updated = try writer.update(id: id) { model in
            model.confirmation = .confirmed
        }
        guard updated != nil else { return false }
        onDidCommit?()
        return true
    }

    /// 待确认账目的笔数与金额合计（首页「含待确认 N 笔」用）。
    ///
    /// 口径说明（PRD 2.3-1）：**pending 计入一切统计**，这里的金额只是"其中有多少还没核对"，
    /// 它不是"要减掉的金额"。所以首页大数字不因为它变化（Q1）。
    ///
    /// 为什么只扫订阅来源的账目：`pending` 的唯一产生点是 `validated` 的第 ⑥ 步，
    /// 而那里只有 `source == .subscription` 才可能给出 `.pending`
    /// （手动 / 待办恒为 confirmed）。于是"扫订阅来源"与"扫全表"结果相同，
    /// 但代价从"全库账目"降到"订阅账目"——首页每次 `load()` 都会调它。
    /// 恢复逻辑（`TrashService.restore`）写回快照时不会改变来源，这个前提始终成立。
    ///
    /// - Returns: `(笔数, 金额合计)`。没有待确认账目时返回 `(0, .zero)`。
    func pendingSummary() throws -> (count: Int, amount: Money) {
        let pending = try pendingEntries()
        var cents: Int64 = 0
        for entry in pending {
            cents += entry.amount
        }
        return (pending.count, Money(cents: cents))
    }

    /// 确认全部待确认账目（首页行动条 / 待确认页的「全部确认」）。
    ///
    /// **一次 `save()` + 一条 `onDidCommit`**：20 笔待确认如果逐笔 `confirm`，
    /// 就是 20 次 SQLite 事务 + 20 次列表重建，用户会看到列表闪烁十几下。
    /// 一次事务还保证了"要么全确认、要么全不动"——中途失败不会留下半批状态。
    ///
    /// 写法照抄项目既有的批量范式（`SweepCoordinator.applyBatch`）：逐笔
    /// `writer.update(model, save: false)` 改字段，最后一次 `writer.save()` 提交。
    /// 不用 `writer.update(id:)` 是因为它内部会自己写 `updatedAt` 并逐笔 `save()`，
    /// 那样这两个"一批一次"的保证都不成立；属性赋值也仍然发生在 `writer` 的闭包内（A3）。
    ///
    /// - Returns: 实际确认的笔数。
    @discardableResult
    func confirmAll() throws -> Int {
        let pending = try pendingEntries()
        guard !pending.isEmpty else { return 0 }

        let now = Date()
        for entry in pending {
            try writer.update(entry, save: false) { model in
                model.confirmRaw = EntryConfirmation.confirmed.raw
                model.updatedAt = now
            }
        }
        try writer.save()
        onDidCommit?()
        return pending.count
    }

    /// 当前所有待确认、且未被软删的账目（按应扣日倒序，最近的排在前面）。
    ///
    /// 排序在内存里做：`QueryDescriptors` 的订阅来源描述符已按 `occurredDay` 正序返回，
    /// 这里反转即可，不需要第二个 desc（`QueryDescriptors` 本批零改动）。
    ///
    /// 为什么对外可见（而不是只给 `pendingSummary` / `confirmAll` 用）：
    /// 核对页（`PendingReviewView`）要逐笔展示"哪几笔还没核对"，与统计口径必须同源。
    /// 若让视图自己查一遍，界面上的笔数和「全部确认」实际确认的笔数会在
    /// "刚被别的页面确认掉一笔"这种时刻对不上——同一个筛选逻辑只能有一份。
    func pendingEntries() throws -> [LedgerEntry] {
        let entries = try writer.fetch(QueryDescriptors.entries(ofSource: .subscription))
        return entries
            .filter { $0.isPending && !$0.isDeleted }
            .sorted { $0.occurredDay > $1.occurredDay }
    }

    // MARK: - 查询

    /// 某月的账目（未软删，日期倒序）。
    func entries(in monthKey: Int32) throws -> [LedgerEntry] {
        try writer.fetch(QueryDescriptors.monthEntries(monthKey))
    }

    /// 某月、某分类的账目（单月内存过滤：Optional 关系谓词在 iOS 17 有崩溃面，见 `QueryDescriptors`）。
    func entries(in monthKey: Int32, categoryID: UUID) throws -> [LedgerEntry] {
        try entries(in: monthKey).filter { $0.category?.id == categoryID }
    }

    /// 月度汇总（支出 / 收入 / 结余）。
    ///
    /// - Parameter monthKey: `yyyyMM`。
    /// - Returns: 汇总值；该月无数据时返回 `.zero`。
    func monthSummary(monthKey: Int32) throws -> MonthSummary {
        let entries = try entries(in: monthKey)
        var expenseCents: Int64 = 0
        var incomeCents: Int64 = 0

        for entry in entries {
            switch entry.type {
            case .expense:
                expenseCents += entry.amount
            case .income:
                incomeCents += entry.amount
            case .transfer:
                // 转账是账户间搬钱，既不是支出也不是收入，绝不计入月度收支
                continue
            }
        }
        return MonthSummary(expense: Money(cents: expenseCents), income: Money(cents: incomeCents))
    }

    /// 账户余额（R-ACC-1）。
    ///
    /// 直接走账户的关系（`entries` + `incomingTransfers`），不需要额外查询：
    /// 既避开 Optional 关系谓词，又天然覆盖了转账的两侧。
    ///
    /// - Parameter accountID: 账户 id。
    /// - Returns: 余额。
    func accountBalance(accountID: UUID) throws -> Money {
        guard let account = try writer.account(id: accountID) else { return .zero }
        let snapshot = AccountBalanceCalculator.AccountSnapshot(
            id: account.id,
            initialBalanceCents: account.initialBalance,
            kindRaw: account.kindRaw
        )
        let movements = ((account.entries ?? []) + (account.incomingTransfers ?? [])).map { entry in
            AccountBalanceCalculator.Movement(
                amountCents: entry.amount,
                typeRaw: entry.typeRaw,
                accountID: entry.account?.id,
                toAccountID: entry.toAccount?.id,
                isDeleted: entry.isDeleted
            )
        }
        return AccountBalanceCalculator.balance(account: snapshot, movements: movements)
    }

    /// 读取单条账目（详情页按 id 取值的兜底路径）。
    func entry(id: UUID) throws -> LedgerEntry? {
        try writer.entry(id: id)
    }

    // MARK: - 校验

    /// 校验并把幂等键补齐，返回可以直接落库的草稿。
    private func validated(_ draft: EntryDraft) throws -> EntryDraft {
        var prepared = draft

        // ① 金额
        guard prepared.amount > 0 else { throw LedgerError.amountNotPositive }

        // ② 日期（真实且不是未来）
        try validateDay(prepared.occurredDay)

        // ③ 备注长度
        guard prepared.note.count <= LedgerService.noteLimit else { throw LedgerError.noteTooLong }

        // ④ 账户 / 分类 / 转账目标
        guard prepared.accountID != nil, try writer.account(id: prepared.accountID) != nil else {
            throw LedgerError.missingAccount
        }

        if prepared.type == .transfer {
            guard let targetID = prepared.toAccountID else { throw LedgerError.missingTransferTarget }
            guard targetID != prepared.accountID else { throw LedgerError.sameTransferAccount }
            guard try writer.account(id: targetID) != nil else { throw LedgerError.missingTransferTarget }
            // 转账没有分类（PRD 3.2.1），强制清空，避免把支出分类带到转账上
            prepared.categoryID = nil
        } else {
            guard let categoryID = prepared.categoryID,
                  try writer.category(id: categoryID) != nil else {
                throw LedgerError.missingCategory
            }
        }

        // ⑤ 幂等键补齐（拼接实现只有一处：SubscriptionSnapshot.makeUniqueKey）
        if prepared.uniqueKey == nil {
            switch prepared.source {
            case .manual:
                break
            case .todo:
                if let todoID = prepared.sourceRefID {
                    prepared.uniqueKey = "todo|\(todoID.uuidString)"
                }
            case .subscription:
                if let subID = prepared.sourceRefID, let cycleKey = prepared.sourceCycleKey {
                    prepared.uniqueKey = SubscriptionSnapshot.makeUniqueKey(
                        subscriptionID: subID,
                        cycleKey: cycleKey
                    )
                }
            }
        }

        // ⑥ 确认状态（V1.1 F-SUB-13）
        //
        // **只在调用方没给值时判定**：显式传入的 `confirmRaw` 必须原样保留。
        // 这条 "if" 不是防御性代码，而是契约——`EntryDraft.confirmRaw` 的文档写明
        // "nil = 由业务层判定"，于是"业务层判定"只能发生在 nil 上；否则
        // `SweepAction` 好不容易算好的结果会被这里无声覆盖，而且两处算法一旦分叉，
        // 订阅账目的徽标就会随写入路径随机变化。
        //
        // `today` 必须来自 `todayProvider()`（架构 R7）：`Date()` 在这里是错的——
        // 冷启动补漏会生成几十天前的历史账目，用"现在"当基准会把它们全部标成待确认。
        if prepared.confirmRaw == nil {
            switch prepared.source {
            case .subscription:
                prepared.confirmRaw = EntryConfirmation.forSubscription(
                    occurredDay: prepared.occurredDay,
                    today: todayProvider()
                ).raw
            case .manual, .todo:
                // 手动记账是用户自己敲的，待办完成时那次点击本身就是一次人工确认
                prepared.confirmRaw = EntryConfirmation.confirmed.raw
            }
        }

        return prepared
    }

    /// 发生日校验：必须是真实自然日，且不得晚于今天。
    private func validateDay(_ day: Int32) throws {
        let dateOnly = DateOnly(key: day)
        guard dateOnly.isValid else { throw LedgerError.invalidDate }
        guard dateOnly <= todayProvider() else { throw LedgerError.futureDate }
    }
}
