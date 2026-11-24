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
            didSpawnNextOccurrence: spawned
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
        }

        try writer.save()
        onDidCommit?()
    }

    // MARK: - 重复实例

    /// 生成下一期重复实例。
    ///
    /// - Returns: 是否真的生成了（无重复规则 / 无截止日时返回 false）。
    @discardableResult
    private func spawnNextOccurrenceIfNeeded(_ todo: Todo) throws -> Bool {
        guard todo.repeatRule != .none,
              let unit = todo.repeatRule.cycleUnit,
              let dueDate = todo.dueDate else { return false }

        let interval = max(todo.repeatInterval, 1)
        let nextDue = CycleAdvancer.advance(
            from: dueDate,
            unit: unit,
            value: interval,
            anchorDay: dueDate.day
        )
        guard nextDue.key > dueDate.key else { return false }

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
        return true
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
