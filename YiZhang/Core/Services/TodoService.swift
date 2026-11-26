//
//  TodoService.swift
//  一账 / Core / Services
//
//  职责：待办用例层（T15，PRD 附录 A.3）——增删改 + 「完成」+ 「确认记账」+ 撤销完成 + 重复实例。
//
//  ## 为什么"完成"必须是两步（本文件最重要的设计）
//
//  R-TODO-1…R-TODO-5 描述的不是"一个动作"，而是**一次询问**：
//  用户勾选完成 → 若这件待办带花销，系统问"这笔花了多少，记在哪" → 用户答完才落账。
//
//  如果把两件事合成一个方法，只有两种收场：
//  ① 勾选即记账 → 用户没确认就多了一笔账，R-TODO-4 的"不记账"出口无处安放；
//  ② 勾选什么都不做，等用户点确认才置 done → "确认条弹出时 App 被杀"会留下
//     一条**看着已完成、其实没完成**的待办（这正是架构 §3.7 拒绝 `pending` 状态的原因）。
//
//  所以拆成：
//  - `complete(id:)`：**立刻**置 done（这是用户真实的意图，且不可丢），
//    若带花销则返回 `TodoCompletionRequest`（只是"要不要记账 + 记多少"的问题，不是状态）；
//  - `confirmCompletion(_:for:)`：拿到答案后写账目 + 回写 `linkedEntryID`。
//  两条路径都不产生"半完成"状态，App 在两步之间被杀也只是"待办已完成、账目没记"，
//  用户下次可以在账目列表手动补一笔——这比僵尸状态好处理得多。
//
//  ## 其他三条纪律
//  ① **未完成待办绝不预留账目**（R-TODO-8）：本类只在 `confirmCompletion` 里写账。
//  ② **改金额不回写 `estimatedAmount`**（R-TODO-6）：预计是"当初的计划"，实际是"花了多少"，
//     两者写进同一个字段就再也分不开了。
//  ③ **重复待办在 `complete` 时生成下一期**：完成后才生成，删除这一期不会连带删掉下一期；
//     下一期继承标题/金额/分类/账户/重复规则，`completedAt` 清空。
//

import Foundation
import SwiftData

// MARK: - 错误

/// 待办相关的业务错误。
enum TodoError: LocalizedError, Equatable {
    /// 标题为空
    case titleEmpty
    /// 标题超过 60 字（PRD 5.1）
    case titleTooLong
    /// 备注超过 500 字
    case noteTooLong
    /// 待办不存在
    case todoNotFound
    /// 截止日非法
    case invalidDueDay
    /// 截止时间非法（0…1439 或 -1）
    case invalidDueTime
    /// 已经完成过了
    case alreadyCompleted
    /// 还没完成，不能撤销完成
    case notCompleted
    /// 重复间隔非法
    case invalidRepeatInterval
    /// 提醒时间非法
    case invalidReminderMinutes
    /// 找不到分类
    case missingCategory
    /// 找不到账户
    case missingAccount
    /// 确认时报了一个负数金额
    case invalidAmount

    var errorDescription: String? {
        switch self {
        case .titleEmpty: return "待办标题不能为空"
        case .titleTooLong: return "标题最多 60 个字"
        case .noteTooLong: return "备注最多 500 个字"
        case .todoNotFound: return "这条待办已不存在"
        case .invalidDueDay: return "截止日期无效"
        case .invalidDueTime: return "截止时间无效"
        case .alreadyCompleted: return "这条待办已经完成了"
        case .notCompleted: return "这条待办还没完成"
        case .invalidRepeatInterval: return "重复间隔需要在 1 到 366 之间"
        case .invalidReminderMinutes: return "提醒时间无效"
        case .missingCategory: return "请先创建一个支出分类"
        case .missingAccount: return "请先创建一个账户"
        case .invalidAmount: return "金额不能为负"
        }
    }
}

// MARK: - 输入

/// 新建待办的输入。
struct TodoDraft: Hashable, Sendable {

    var title: String = ""
    var note: String = ""
    /// 截止日 `yyyyMMdd`；`0` = 无日期。
    var dueDay: Int32 = 0
    /// 截止时间（当日分钟数）；`-1` = 无具体时间。
    var dueTimeMinutes: Int32 = -1
    var hasExpense: Bool = false
    var hasEstimatedAmount: Bool = false
    /// 预计金额（分）。
    var estimatedAmount: Int64 = 0
    var priority: TodoPriority = .none
    var repeatRule: RepeatRule = .none
    var repeatInterval: Int = 1
    var categoryID: UUID?
    var accountID: UUID?
    /// 提醒日 `yyyyMMdd`；`0` = 不提醒。
    var reminderDay: Int32 = 0
    /// 提醒时间（当日分钟数）；`-1` = 默认 09:00。
    var reminderMinutes: Int32 = -1

    init(
        title: String = "",
        note: String = "",
        dueDay: Int32 = 0,
        dueTimeMinutes: Int32 = -1,
        hasExpense: Bool = false,
        hasEstimatedAmount: Bool = false,
        estimatedAmount: Int64 = 0,
        priority: TodoPriority = .none,
        repeatRule: RepeatRule = .none,
        repeatInterval: Int = 1,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        reminderDay: Int32 = 0,
        reminderMinutes: Int32 = -1
    ) {
        self.title = title
        self.note = note
        self.dueDay = dueDay
        self.dueTimeMinutes = dueTimeMinutes
        self.hasExpense = hasExpense
        self.hasEstimatedAmount = hasEstimatedAmount
        self.estimatedAmount = estimatedAmount
        self.priority = priority
        self.repeatRule = repeatRule
        self.repeatInterval = repeatInterval
        self.categoryID = categoryID
        self.accountID = accountID
        self.reminderDay = reminderDay
        self.reminderMinutes = reminderMinutes
    }
}

/// 编辑待办时的可变字段（`nil` = 不改）。
///
/// **不提供** `status` / `completedAt` / `linkedEntryID`：完成与撤销完成各有语义方法
/// （`complete` / `confirmCompletion` / `reopen`），从类型上就杜绝"改字段把状态改坏"。
struct TodoChanges: Hashable, Sendable {
    var title: String?
    var note: String?
    var dueDay: Int32?
    var dueTimeMinutes: Int32?
    var hasExpense: Bool?
    var hasEstimatedAmount: Bool?
    var estimatedAmount: Int64?
    var priority: TodoPriority?
    var repeatRule: RepeatRule?
    var repeatInterval: Int?
    var categoryID: UUID?
    var accountID: UUID?
    var reminderDay: Int32?
    var reminderMinutes: Int32?

    init(
        title: String? = nil,
        note: String? = nil,
        dueDay: Int32? = nil,
        dueTimeMinutes: Int32? = nil,
        hasExpense: Bool? = nil,
        hasEstimatedAmount: Bool? = nil,
        estimatedAmount: Int64? = nil,
        priority: TodoPriority? = nil,
        repeatRule: RepeatRule? = nil,
        repeatInterval: Int? = nil,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        reminderDay: Int32? = nil,
        reminderMinutes: Int32? = nil
    ) {
        self.title = title
        self.note = note
        self.dueDay = dueDay
        self.dueTimeMinutes = dueTimeMinutes
        self.hasExpense = hasExpense
        self.hasEstimatedAmount = hasEstimatedAmount
        self.estimatedAmount = estimatedAmount
        self.priority = priority
        self.repeatRule = repeatRule
        self.repeatInterval = repeatInterval
        self.categoryID = categoryID
        self.accountID = accountID
        self.reminderDay = reminderDay
        self.reminderMinutes = reminderMinutes
    }
}

// MARK: - 完成请求

/// 「这条待办完成了，要不要记一笔账？」的请求对象。
///
/// 它**不是**待办状态，只是一份带默认值的表单数据；`needsConfirmation == false` 时
/// UI 应当零打扰（R-TODO-5），连确认条都不弹。
struct TodoCompletionRequest: Hashable, Sendable {

    let todoID: UUID
    let title: String
    /// 预计金额（分）；未填金额时为 nil。
    let estimatedAmount: Int64?
    /// 是否真的填过金额（区分"未填"与"填了 0"）。
    let hasEstimatedAmount: Bool
    let categoryID: UUID?
    let accountID: UUID?
    /// 完成时刻（账目的发生日取它"当天"）。
    let completedAt: Date
    /// 是否完成了带花销的待办（= 需要弹确认条）。
    let hasExpense: Bool
    /// 重复规则（用于 UI 上提示"完成后会自动生成下一期"）。
    let repeatRule: RepeatRule
    /// 是否顺手生成了下一期重复实例。
    let didSpawnNextOccurrence: Bool

    /// 是否需要 UI 询问金额（R-TODO-1 / R-TODO-5）。
    var needsConfirmation: Bool { hasExpense }

    /// 确认条里的金额默认值。
    var suggestedAmount: Money? {
        guard hasEstimatedAmount else { return nil }
        return Money(cents: max(estimatedAmount ?? 0, 0))
    }
}

/// 用户在确认条里给出的答案。
struct CompletionConfirmation: Hashable, Sendable {

    /// 实际金额（分）。`nil` 或 `0` 表示「不记账」（R-TODO-4）。
    var amountCents: Int64?
    var categoryID: UUID?
    var accountID: UUID?

    init(amountCents: Int64? = nil, categoryID: UUID? = nil, accountID: UUID? = nil) {
        self.amountCents = amountCents
        self.categoryID = categoryID
        self.accountID = accountID
    }

    /// 「不记账」的选择。
    static let skipEntry = CompletionConfirmation()

    /// 是否要写账。
    var shouldCreateEntry: Bool { (amountCents ?? 0) > 0 }
}

// MARK: - 删除凭据

/// 一条待办的**全字段**快照（V1.1 / F-TODO-11「删除此次及以后」的撤销凭据）。
///
/// 为什么不用 `Todo`（模型）而用值类型：
/// ① 删除后模型已经不在库里，撤销要重建一个**全新**的 `Todo`，手里必须有一份脱离
///    SwiftData identity map 的纯数据；
/// ② 撤销的正确性标准是"逐字段一致"（收工标准 ⑫），值类型让这条断言可以写成
///    `XCTAssertEqual(receipt.snapshot, TodoSnapshot(todo: restored))` 一句，
///    而不是十几个散落的字段比较（漏一个就悄悄丢数据）。
///
/// 字段清单 = `Todo` 的全部标量 + 四个关系的 id。**加字段时同步两处**：
/// 本结构体 + `restore(from:)`。
struct TodoSnapshot: Hashable, Sendable {

    let id: UUID
    let title: String
    let note: String
    let dueDay: Int32
    let dueTimeMinutes: Int32
    let hasExpense: Bool
    let hasEstimatedAmount: Bool
    let estimatedAmount: Int64
    let priorityRaw: String
    let repeatRuleRaw: String
    let repeatInterval: Int
    let statusRaw: String
    let completedAt: Date?
    let reminderDay: Int32
    let reminderMinutes: Int32
    let linkedEntryID: UUID?
    let createdAt: Date
    let updatedAt: Date
    // 关系（只存 id：撤销时重新解析，解析不到就留 nil）
    let categoryID: UUID?
    let accountID: UUID?
    let sourceSubscriptionID: UUID?

    init(todo: Todo) {
        id = todo.id
        title = todo.title
        note = todo.note
        dueDay = todo.dueDay
        dueTimeMinutes = todo.dueTimeMinutes
        hasExpense = todo.hasExpense
        hasEstimatedAmount = todo.hasEstimatedAmount
        estimatedAmount = todo.estimatedAmount
        priorityRaw = todo.priorityRaw
        repeatRuleRaw = todo.repeatRuleRaw
        repeatInterval = todo.repeatInterval
        statusRaw = todo.statusRaw
        completedAt = todo.completedAt
        reminderDay = todo.reminderDay
        reminderMinutes = todo.reminderMinutes
        linkedEntryID = todo.linkedEntryID
        createdAt = todo.createdAt
        updatedAt = todo.updatedAt
        categoryID = todo.category?.id
        accountID = todo.account?.id
        sourceSubscriptionID = todo.sourceSubscription?.id
    }

    /// 这条待办是否属于一个重复系列（`repeatRule != .none`）。
    var isRepeating: Bool { repeatRuleRaw != RepeatRule.none.raw }

    /// 截止日（`0` = 无日期）。
    var dueDate: DateOnly? {
        dueDay > 0 ? DateOnly(key: dueDay) : nil
    }
}

/// 一次「删除」的完整回执。
///
/// 三个字段各自回答撤销时的一个问题：
/// - `snapshot`：怎么把这行原样放回去；
/// - `spawnedNextID`：撤销时要不要先删掉删除动作**顺带生成**的那一期
///   （漏了它，撤销「删除这一期」会留下两行 —— 收工标准 ⑬）；
/// - `deletedAt`：Toast / 日志用，也用于「撤销只在 3 秒内有效」的口径说明。
struct TodoDeletionReceipt: Hashable, Sendable {
    let snapshot: TodoSnapshot
    /// 这次删除是否**终止了一个重复系列**（`snapshot.isRepeating`）。
    let stoppedSeries: Bool
    /// 删除时顺便生成的下一期 id（「删除这一期」才会有；「删除此次及以后」恒为 nil）。
    let spawnedNextID: UUID?
    let deletedAt: Date
}

// MARK: - 服务

/// 待办服务。
@MainActor
final class TodoService {

    /// 标题长度上限（PRD 5.1）。
    static let titleLimit = 60
    /// 备注长度上限。
    static let noteLimit = 500
    /// 重复间隔范围。
    static let repeatIntervalRange = 1...366

    private let writer: LedgerWriter
    private let ledger: LedgerService

    /// 写入提交后的回调（由 `AppEnvironment` 接到 `bumpDataVersion()`）。
    var onDidCommit: (() -> Void)?

    /// **软删之后**的清理钩子（V1.1；`reopen(keepEntry: false)` 是本类唯一的软删入口）。
    ///
    /// 语义与 `LedgerService.onDidSoftDelete` 一致：闭包单向出去，避免
    /// `TodoService ↔ TrashService` 成环。
    var onDidSoftDelete: (() -> Void)?

    init(writer: LedgerWriter, ledger: LedgerService, onDidCommit: (() -> Void)? = nil) {
        self.writer = writer
        self.ledger = ledger
        self.onDidCommit = onDidCommit
    }

    // MARK: - 读

    /// 全部待办（按截止日升序，无日期在后）。
    func todos() throws -> [Todo] {
        try writer.fetch(QueryDescriptors.allTodos())
    }

    /// 未完成待办。
    func openTodos() throws -> [Todo] {
        try writer.fetch(QueryDescriptors.openTodos())
    }

    /// 单条待办。
    func todo(id: UUID) throws -> Todo? {
        try writer.todo(id: id)
    }

    // MARK: - 新建 / 编辑 / 删除

    /// 新建待办。
    ///
    /// - Parameter draft: 待办草稿。
    /// - Returns: 新待办的 id。
    @discardableResult
    func create(_ draft: TodoDraft) throws -> UUID {
        let title = try validatedTitle(draft.title)
        let note = try validatedNote(draft.note)
        try validateDue(day: draft.dueDay, minutes: draft.dueTimeMinutes)
        let interval = try validatedRepeatInterval(draft.repeatRule, draft.repeatInterval)
        try validateReminder(minutes: draft.reminderMinutes)

        let todo = Todo()
        todo.title = title
        todo.note = note
        todo.dueDay = max(draft.dueDay, 0)
        todo.dueTimeMinutes = draft.dueTimeMinutes
        todo.hasExpense = draft.hasExpense
        todo.hasEstimatedAmount = draft.hasEstimatedAmount
        todo.estimatedAmount = max(draft.estimatedAmount, 0)
        todo.priority = draft.priority
        todo.repeatRule = draft.repeatRule
        todo.repeatInterval = interval
        todo.status = .open
        todo.completedAt = nil
        todo.reminderDay = max(draft.reminderDay, 0)
        todo.reminderMinutes = draft.reminderMinutes
        todo.linkedEntryID = nil
        todo.createdAt = Date()
        todo.updatedAt = Date()

        if draft.hasExpense {
            todo.category = try resolvedCategory(draft.categoryID)
            todo.account = try resolvedAccount(draft.accountID)
        } else {
            todo.category = nil
            todo.account = nil
        }

        try writer.insert(todo)
        onDidCommit?()
        return todo.id
    }

    /// 编辑待办。**不改状态、不改关联账目、不回写预计金额**（R-TODO-6）。
    func update(id: UUID, changing changes: TodoChanges) throws {
        guard let todo = try writer.todo(id: id) else { throw TodoError.todoNotFound }

        if let rawTitle = changes.title {
            todo.title = try validatedTitle(rawTitle)
        }
        if let rawNote = changes.note {
            todo.note = try validatedNote(rawNote)
        }
        if let dueDay = changes.dueDay {
            todo.dueDay = max(dueDay, 0)
        }
        if let minutes = changes.dueTimeMinutes {
            try validateDue(day: todo.dueDay, minutes: minutes)
            todo.dueTimeMinutes = minutes
        }
        if let hasExpense = changes.hasExpense {
            todo.hasExpense = hasExpense
            if !hasExpense {
                // 关掉花销：分类/账户一并清掉，避免留下"没有花销却有分类"的脏数据
                todo.category = nil
                todo.account = nil
            }
        }
        if let hasEstimatedAmount = changes.hasEstimatedAmount {
            todo.hasEstimatedAmount = hasEstimatedAmount
            if !hasEstimatedAmount { todo.estimatedAmount = 0 }
        }
        if let amount = changes.estimatedAmount {
            todo.estimatedAmount = max(amount, 0)
        }
        if let priority = changes.priority {
            todo.priority = priority
        }
        if let rule = changes.repeatRule {
            todo.repeatRule = rule
            todo.repeatInterval = try validatedRepeatInterval(rule, todo.repeatInterval)
        }
        if let interval = changes.repeatInterval {
            todo.repeatInterval = try validatedRepeatInterval(todo.repeatRule, interval)
        }
        if let categoryID = changes.categoryID {
            todo.category = todo.hasExpense ? try resolvedCategory(categoryID) : nil
        }
        if let accountID = changes.accountID {
            todo.account = todo.hasExpense ? try resolvedAccount(accountID) : nil
        }
        if let reminderDay = changes.reminderDay {
            todo.reminderDay = max(reminderDay, 0)
        }
        if let minutes = changes.reminderMinutes {
            try validateReminder(minutes: minutes)
            todo.reminderMinutes = minutes
        }

        todo.updatedAt = Date()
        try writer.save()
        onDidCommit?()
    }

    /// 删除待办（硬删：模型没有软删字段）。
    ///
    /// 关联账目**不删**：那笔钱已经花出去了，删待办不该抹掉支出。
    /// 账目的 `sourceRefID` 悬空后，详情页会显示「来源已删除」。
    func delete(id: UUID) throws {
        guard let todo = try writer.todo(id: id) else { return }
        try writer.delete(todo)
        onDidCommit?()
    }

    // MARK: - 删除重复系列（V1.1 / F-TODO-11）

    /// 删除「此次及以后」：删掉这一期，并且**不再生成下一期**。
    ///
    /// 语义等价于"这个重复到此为止"。已完成的历史记录（以及它们关联的账目）
    /// **一条都不动**——那笔钱确实花出去了，删一条待办不该抹掉它（与 `delete(id:)` 同口径）。
    ///
    /// 原子性：本方法只做一件事（删一行），`writer.delete` 自带 `save()`，
    /// 不存在"删了一半"的中间态。
    ///
    /// - Parameters:
    ///   - id: 待办 id。
    ///   - moment: 删除时刻（测试可注入）。
    /// - Returns: 撤销凭据（`spawnedNextID` 恒为 nil）。
    /// - Throws: `.todoNotFound`。
    @discardableResult
    func deleteAndStopSeries(id: UUID, at moment: Date = Date()) throws -> TodoDeletionReceipt {
        guard let todo = try writer.todo(id: id) else { throw TodoError.todoNotFound }
        let snapshot = TodoSnapshot(todo: todo)
        try writer.delete(todo)
        onDidCommit?()
        return TodoDeletionReceipt(
            snapshot: snapshot,
            stoppedSeries: snapshot.isRepeating,
            spawnedNextID: nil,
            deletedAt: moment
        )
    }

    /// 删除「这一期」：删掉这一期，但**系列继续** —— 顺带生成下一期（跳过这一次）。
    ///
    /// 与「删除此次及以后」的唯一区别就是这里 spawn 了一次。两者必须是**两个方法**：
    /// 用一个 `stopSeries: Bool` 参数会让调用点长出 `delete(id:stopSeries: true)` 这种
    /// 读不出意图的代码，而这两件事在 PRD 里是两个不同的按钮。
    ///
    /// 原子性（风险 R-TODO-9）：spawn 的插入与本次删除**共用同一次 `save()`**。
    /// 若分成两次提交，App 在中间被杀就会得到"这一期没了、下一期也没生成"，
    /// 用户的重复待办从此静默消失——这是最不该出现的一种数据丢失。
    ///
    /// - Parameters:
    ///   - id: 待办 id。
    ///   - moment: 删除时刻。
    /// - Returns: 撤销凭据（`spawnedNextID` 为生成的那一期，可能是 nil）。
    /// - Throws: `.todoNotFound`。
    @discardableResult
    func deleteCurrentOccurrence(id: UUID, at moment: Date = Date()) throws -> TodoDeletionReceipt {
        guard let todo = try writer.todo(id: id) else { throw TodoError.todoNotFound }
        let snapshot = TodoSnapshot(todo: todo)

        // 只有**未完成**的重复待办才需要补下一期：
        // 已完成的那条在 `complete` 时已经生成过下一期了，再 spawn 一次会凭空多出一行。
        let spawnedNextID = todo.isOpen ? try spawnNextOccurrenceIfNeeded(todo) : nil

        // save: false —— 与上面的插入落在同一次提交里
        try writer.delete(todo, save: false)
        try writer.save()
        onDidCommit?()

        return TodoDeletionReceipt(
            snapshot: snapshot,
            stoppedSeries: snapshot.isRepeating,
            spawnedNextID: spawnedNextID,
            deletedAt: moment
        )
    }

    /// 撤销一次删除（3 秒 Toast 上的「撤销」）。
    ///
    /// 两件事必须做对：
    /// ① **复用原 id**。`Todo.id` 没有 `.unique` 约束，技术上可以换新 UUID；但换掉之后
    ///    账目的 `sourceRefID`（指向待办 id）会悬空、已排好的通知标识也对不上，
    ///    用户看到的是"撤销回来了，但那笔账的「来源」不见了"。
    /// ② **先清掉删除时 spawn 的那一期**，再把原行放回去。顺序反了（先插后删）也能得到
    ///    同样的结果，但"先删"让中间态永远只有 0 或 1 行重复待办，不会短暂出现两行。
    ///
    /// 一次 `save()` 提交，中途被杀就整体不生效 —— 撤销失败比只撤销一半好。
    ///
    /// - Parameter receipt: `deleteAndStopSeries` / `deleteCurrentOccurrence` 的返回值。
    /// - Throws: 写入失败。
    func undoDeletion(_ receipt: TodoDeletionReceipt) throws {
        // 已经存在同名 id（例如连点两次「撤销」）：什么都不做，避免主键冲突式的重复插入
        if try writer.todo(id: receipt.snapshot.id) != nil { return }

        if let spawnedNextID = receipt.spawnedNextID,
           let spawned = try writer.todo(id: spawnedNextID) {
            try writer.delete(spawned, save: false)
        }

        let todo = Todo()
        try restore(todo, from: receipt.snapshot)
        try writer.insert(todo, save: false)
        try writer.save()
        onDidCommit?()
    }

    /// 把快照写回一个新建的 `Todo`（撤销专用）。
    ///
    /// 关系现场解析：分类 / 账户 / 订阅 / 关联账目可能在这 3 秒里被别处删掉，
    /// 解析不到就留 nil —— 让撤销成功、丢一个引用，好过让撤销整体失败。
    private func restore(_ todo: Todo, from snapshot: TodoSnapshot) throws {
        todo.id = snapshot.id
        todo.title = snapshot.title
        todo.note = snapshot.note
        todo.dueDay = snapshot.dueDay
        todo.dueTimeMinutes = snapshot.dueTimeMinutes
        todo.hasExpense = snapshot.hasExpense
        todo.hasEstimatedAmount = snapshot.hasEstimatedAmount
        todo.estimatedAmount = snapshot.estimatedAmount
        todo.priorityRaw = snapshot.priorityRaw
        todo.repeatRuleRaw = snapshot.repeatRuleRaw
        todo.repeatInterval = snapshot.repeatInterval
        todo.statusRaw = snapshot.statusRaw
        todo.completedAt = snapshot.completedAt
        todo.reminderDay = snapshot.reminderDay
        todo.reminderMinutes = snapshot.reminderMinutes
        todo.linkedEntryID = snapshot.linkedEntryID
        todo.createdAt = snapshot.createdAt
        todo.updatedAt = snapshot.updatedAt

        todo.category = try writer.category(id: snapshot.categoryID)
        todo.account = try writer.account(id: snapshot.accountID)
        if let subscriptionID = snapshot.sourceSubscriptionID {
            todo.sourceSubscription = try writer.subscription(id: subscriptionID)
        }
        if let entryID = snapshot.linkedEntryID {
            todo.linkedEntry = try writer.entry(id: entryID)
        }
    }

    // MARK: - 完成（第一步）

    /// 勾选完成：**立刻**置 done，带花销则返回待确认的请求对象。
    ///
    /// - Parameter id: 待办 id。
    /// - Returns: 完成请求；`needsConfirmation == false` 表示 UI 不需要弹任何东西。
    @discardableResult
    func complete(id: UUID, at moment: Date = Date()) throws -> TodoCompletionRequest {
        guard let todo = try writer.todo(id: id) else { throw TodoError.todoNotFound }
        guard todo.isOpen else { throw TodoError.alreadyCompleted }

        todo.status = .done
        todo.completedAt = moment
        todo.updatedAt = moment

        // 重复待办：完成即生成下一期（下一期是独立记录，删这一期不会牵连它）
        let spawned = try spawnNextOccurrenceIfNeeded(todo)
        try writer.save()
        onDidCommit?()

        return TodoCompletionRequest(
            todoID: todo.id,
            title: todo.displayTitle,
            estimatedAmount: todo.hasEstimatedAmount ? todo.estimatedAmount : nil,
            hasEstimatedAmount: todo.hasEstimatedAmount,
            categoryID: todo.category?.id,
            accountID: todo.account?.id,
            completedAt: moment,
            hasExpense: todo.hasExpense,
            repeatRule: todo.repeatRule,
            didSpawnNextOccurrence: spawned != nil
        )
    }

    // MARK: - 确认记账（第二步）

    /// 拿到用户的答案后写账目并回写 `linkedEntryID`。
    ///
    /// - Parameters:
    ///   - confirmation: 金额 + 分类 + 账户（金额为 nil/0 = 不记账）。
    ///   - request: `complete(id:)` 返回的请求。
    /// - Returns: 插入结果；**不记账时返回 nil**（不是错误，是用户明确的选择）。
    @discardableResult
    func confirmCompletion(
        _ confirmation: CompletionConfirmation,
        for request: TodoCompletionRequest
    ) throws -> InsertOutcome? {
        guard let todo = try writer.todo(id: request.todoID) else {
            throw TodoError.todoNotFound
        }
        // 已完成后才允许确认；若是"取消完成"又点了确认，这里挡住
        guard todo.isDone else { throw TodoError.notCompleted }

        guard let amountCents = confirmation.amountCents, amountCents > 0 else {
            // R-TODO-4：只置 done，不产生账目
            return nil
        }
        if amountCents < 0 { throw TodoError.invalidAmount }

        guard let category = try resolveCategoryObject(confirmation.categoryID ?? request.categoryID) else {
            throw TodoError.missingCategory
        }
        guard let account = try resolveAccountObject(confirmation.accountID ?? request.accountID) else {
            throw TodoError.missingAccount
        }

        var draft = EntryDraft(
            typeRaw: EntryType.expense.raw,
            amount: amountCents,
            occurredDay: DateOnly(request.completedAt).key
        )
        draft.categoryID = category.id
        draft.accountID = account.id
        draft.note = request.title
        draft.sourceRaw = EntrySource.todo.raw
        draft.sourceRefID = request.todoID
        // 幂等键由 `LedgerService` 补成 "todo|<id>"，本类不再拼一次

        let outcome = try ledger.create(draft)

        if case .inserted(let entryID) = outcome {
            try writer.update(todo) { model in
                model.linkedEntryID = entryID
                model.updatedAt = Date()
            }
            onDidCommit?()
        }
        return outcome
    }

    // MARK: - 撤销完成

    /// 撤销完成（R-TODO-7）。
    ///
    /// - Parameters:
    ///   - id: 待办 id。
    ///   - keepEntry: `true` 保留关联账目（默认，钱确实花了）；`false` 软删关联账目。
    func reopen(id: UUID, keepEntry: Bool = true) throws {
        guard let todo = try writer.todo(id: id) else { throw TodoError.todoNotFound }
        guard todo.isDone else { throw TodoError.notCompleted }

        let linkedID = todo.linkedEntryID
        var didSoftDeleteEntry = false
        todo.status = .open
        todo.completedAt = nil
        todo.updatedAt = Date()

        if keepEntry {
            // 保留账目，只断开关联：这笔钱仍然是支出，只是不再属于这条待办
            todo.linkedEntryID = nil
        } else if let linkedID {
            // 软删（R-EDIT-3 的同一套语义）：账目仍可被恢复
            try writer.softDelete(id: linkedID, at: Date())
            todo.linkedEntryID = nil
            didSoftDeleteEntry = true
        }

        try writer.save()
        onDidCommit?()
        // 只有真的软删了账目才清理回收站：`keepEntry == true` 时本方法没往回收站里放东西，
        // 跑一次全表清理纯属浪费（这条路径在"撤销完成"里很常见）。
        if didSoftDeleteEntry {
            onDidSoftDelete?()
        }
    }

    // MARK: - 重复实例

    /// 生成下一期重复实例。
    ///
    /// 返回 **id 而不是 Bool**：V1.1 的「删除这一期」需要把这个 id 塞进
    /// `TodoDeletionReceipt.spawnedNextID`，撤销时才能精确地把它删掉（收工标准 ⑬）。
    /// 用 Bool 的话调用方只能自己再查一次库猜哪一行是刚生成的。
    ///
    /// - Returns: 新生成的那一期 id；**没生成时返回 nil**（无重复规则 / 无截止日 /
    ///   算出来的下一期不比当前晚）。
    @discardableResult
    private func spawnNextOccurrenceIfNeeded(_ todo: Todo) throws -> UUID? {
        guard todo.repeatRule != .none,
              let unit = todo.repeatRule.cycleUnit,
              let dueDate = todo.dueDate else { return nil }

        let interval = max(todo.repeatInterval, 1)
        let nextDue = CycleAdvancer.advance(
            from: dueDate,
            unit: unit,
            value: interval,
            anchorDay: dueDate.day
        )
        guard nextDue.key > dueDate.key else { return nil }

        let next = Todo()
        next.title = todo.title
        next.note = todo.note
        next.dueDay = nextDue.key
        next.dueTimeMinutes = todo.dueTimeMinutes
        next.hasExpense = todo.hasExpense
        next.hasEstimatedAmount = todo.hasEstimatedAmount
        next.estimatedAmount = todo.estimatedAmount
        next.priority = todo.priority
        next.repeatRule = todo.repeatRule
        next.repeatInterval = todo.repeatInterval
        next.status = .open
        next.completedAt = nil
        next.linkedEntryID = nil
        // 提醒日按同样的周期往后推，保证 T20 的通知服务能直接拾取
        if todo.reminderDay > 0 {
            let reminder = DateOnly(key: todo.reminderDay)
            next.reminderDay = CycleAdvancer.advance(
                from: reminder,
                unit: unit,
                value: interval,
                anchorDay: reminder.day
            ).key
        } else {
            next.reminderDay = 0
        }
        next.reminderMinutes = todo.reminderMinutes
        next.category = todo.category
        next.account = todo.account
        next.createdAt = Date()
        next.updatedAt = Date()

        try writer.insert(next, save: false)
        return next.id
    }

    // MARK: - 校验

    private func validatedTitle(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TodoError.titleEmpty }
        guard trimmed.count <= TodoService.titleLimit else { throw TodoError.titleTooLong }
        return trimmed
    }

    private func validatedNote(_ raw: String) throws -> String {
        guard raw.count <= TodoService.noteLimit else { throw TodoError.noteTooLong }
        return raw
    }

    private func validateDue(day: Int32, minutes: Int32) throws {
        if day != 0 {
            guard DateOnly(key: day).isValid else { throw TodoError.invalidDueDay }
        }
        guard minutes == -1 || (0...1439).contains(minutes) else { throw TodoError.invalidDueTime }
    }

    private func validateReminder(minutes: Int32) throws {
        guard minutes == -1 || (0...1439).contains(minutes) else {
            throw TodoError.invalidReminderMinutes
        }
    }

    private func validatedRepeatInterval(_ rule: RepeatRule, _ raw: Int) throws -> Int {
        guard rule != .none else { return 1 }
        guard TodoService.repeatIntervalRange.contains(raw) else {
            throw TodoError.invalidRepeatInterval
        }
        return raw
    }

    private func resolvedCategory(_ preferredID: UUID?) throws -> Category {
        guard let category = try resolveCategoryObject(preferredID) else {
            throw TodoError.missingCategory
        }
        return category
    }

    private func resolvedAccount(_ preferredID: UUID?) throws -> Account {
        guard let account = try resolveAccountObject(preferredID) else {
            throw TodoError.missingAccount
        }
        return account
    }

    /// 优先用给定 id；失效则回落到「其他（支出）」；再不行取第一个支出分类。
    private func resolveCategoryObject(_ preferredID: UUID?) throws -> Category? {
        if let preferredID, let category = try writer.category(id: preferredID) {
            return category
        }
        if let fallback = try writer.category(id: PresetCatalog.otherExpenseCategoryID) {
            return fallback
        }
        let expenses = try writer.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: false)
        )
        return expenses.first
    }

    /// 优先用给定 id；失效则取第一个未归档账户。
    private func resolveAccountObject(_ preferredID: UUID?) throws -> Account? {
        if let preferredID, let account = try writer.account(id: preferredID) {
            return account
        }
        let accounts = try writer.fetch(QueryDescriptors.accounts(includeArchived: false))
        return accounts.first
    }
}
