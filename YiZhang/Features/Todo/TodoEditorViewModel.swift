//
//  TodoEditorViewModel.swift
//  一账 / Features / Todo
//
//  职责：待办新建 / 编辑 / 详情（T17）的全部状态与校验。
//
//  ## 四条刻意的设计
//
//  ① **「有花销」关闭时，金额/分类/账户整块隐藏并且不参与校验**：没勾花销的待办
//     不该被"金额格式不对"这种错误拦住——那是一个与它无关的字段。
//  ② **预计金额允许留空**，留空 ≠ 0：留空是"没打算估"，0 是"预计不花钱"。
//     前者详情页显示「未记录」，后者显示「¥0.00」。所以内部用 `amountText` 而不是 Int64。
//  ③ **预计与已记账两行并存**（R-TODO-6 的 UI 表达）：`estimatedText` 与 `recordedText`
//     是两个独立字段，绝不合并成一个数字——"当初计划 200、实际花了 128"是这个功能的核心信息。
//  ④ **改重复规则只影响下一期**：已生成的下一期实例是独立记录（`TodoService` 的设计），
//     本 VM 只改当前这条的 `repeatRule`，不去追溯已生成的实例。
//

import Foundation
import Observation
import SwiftData

// MARK: - 保存结果

/// `save()` 成功后的结果。
///
/// 只描述「写进库里的那一条」，不含文案 —— 文案是 View 的事（「已添加待办」/「已保存」
/// 取决于 `isNew`，而 `isNew` 只有这里知道）。
///
/// ⚠️ 别把它和 `TodoEditorResult` 搞混：那个是**关闭编辑器时交给调用方的信封**
/// （`.saved` / `.deleted`），这个只是保存这一步的返回值。
struct TodoSaveOutcome: Hashable, Sendable {
    let todoID: UUID
    let isNew: Bool
}

// MARK: - ViewModel

/// 待办编辑页状态机。
@Observable
@MainActor
final class TodoEditorViewModel {

    /// 模式。
    enum Mode: Hashable {
        case create
        case edit(UUID)

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }

        var todoID: UUID? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    // MARK: - 常量

    static let titleLimit = TodoService.titleLimit
    static let noteLimit = TodoService.noteLimit
    static let repeatIntervalRange = TodoService.repeatIntervalRange

    // MARK: - 不可变

    let mode: Mode
    let today: DateOnly

    // MARK: - 可编辑状态

    var title: String = ""
    var note: String = ""

    /// 是否有截止日期。
    var hasDueDate: Bool = true
    var dueDay: DateOnly
    /// 是否有具体截止时间。
    var hasDueTime: Bool = false
    var dueTimeMinutes: Int32 = 9 * 60

    /// 是否带花销（关闭时金额/分类/账户整块隐藏）。
    var hasExpense: Bool = false
    /// 预计金额文本（空 = 未填，与「0 元」不同）。
    var amountText: String = ""
    var categoryID: UUID?
    var accountID: UUID?

    var priority: TodoPriority = .none
    var repeatRule: RepeatRule = .none
    var repeatInterval: Int = 1

    /// 提醒。
    var reminderEnabled: Bool = false
    var reminderDay: DateOnly
    var reminderMinutes: Int32 = 9 * 60

    // MARK: - 只读数据

    private(set) var categories: [CategoryOption] = []
    private(set) var accounts: [AccountOption] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    /// 详情态：这条待办是否已完成。
    private(set) var isDone = false

    /// 这条待办是否属于一个重复系列。
    ///
    /// 只看 `repeatRule`：`repeatInterval` 是「每 N 次」的**修饰**，不是"是否重复"的判据——
    /// 一条 `.none` + `interval 3` 的待办不重复，而一条 `.daily` + `interval 3` 仍然重复。
    var isRepeating: Bool { repeatRule != .none }
    /// 详情态：关联账目 id（可能指向已软删的账目，D22）。
    private(set) var linkedEntryID: UUID?
    /// 详情态：关联账目是否已被软删。
    private(set) var linkedEntryDeleted = false
    /// 详情态：已记账金额文案（`nil` = 没记账）。
    private(set) var recordedText: String?
    private(set) var status: TodoStatus = .open

    // MARK: - 依赖

    private var environment: AppEnvironment?

    // MARK: - 初始化

    init(mode: Mode, today: DateOnly = DateOnly(Date())) {
        self.mode = mode
        self.today = today
        dueDay = today
        reminderDay = today
    }

    // MARK: - 加载

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    func load() {
        guard let environment else { return }
        do {
            categories = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
                .map(CategoryOption.init)
            accounts = try environment.readContext
                .fetch(QueryDescriptors.accounts(includeArchived: false))
                .map(AccountOption.init)

            if let id = mode.todoID {
                try loadExisting(id: id, environment: environment)
            } else {
                applyCreateDefaults(environment)
            }
            errorMessage = nil
        } catch {
            errorMessage = "读取分类和账户失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }
        isLoaded = true
    }

    /// 新建：分类默认最近使用（设置里记的最近分类），账户默认上次使用的。
    private func applyCreateDefaults(_ environment: AppEnvironment) {
        guard !mode.isEditing else { return }
        if categoryID == nil {
            let preferred = environment.settings.recentCategoryIDList.first
            if let preferred, categories.contains(where: { $0.id == preferred }) {
                categoryID = preferred
            } else {
                categoryID = categories.first?.id
            }
        }
        if accountID == nil {
            let preferred = environment.settings.defaultAccountID
            if let preferred, accounts.contains(where: { $0.id == preferred }) {
                accountID = preferred
            } else {
                accountID = accounts.first?.id
            }
        }
    }

    private func loadExisting(id: UUID, environment: AppEnvironment) throws {
        guard let todo = try environment.readContext
            .fetch(QueryDescriptors.todo(id: id))
            .first else {
            errorMessage = "这条待办已不存在"
            return
        }

        title = todo.title
        note = todo.note
        hasDueDate = todo.hasDueDate
        dueDay = todo.dueDate ?? today
        hasDueTime = todo.dueTimeMinutes >= 0
        if todo.dueTimeMinutes >= 0 { dueTimeMinutes = todo.dueTimeMinutes }
        hasExpense = todo.hasExpense
        amountText = todo.hasEstimatedAmount
            ? AmountInput.text(from: Money(cents: max(todo.estimatedAmount, 0)))
            : ""
        categoryID = todo.category?.id
        accountID = todo.account?.id
        priority = todo.priority
        repeatRule = todo.repeatRule
        repeatInterval = max(todo.repeatInterval, 1)
        reminderEnabled = todo.reminderDay > 0
        reminderDay = todo.reminderDate ?? today
        if todo.reminderMinutes >= 0 { reminderMinutes = todo.reminderMinutes }

        status = todo.status
        isDone = todo.isDone
        linkedEntryID = todo.linkedEntryID
        try loadRecordedEntry(todo.linkedEntryID, environment: environment)
    }

    /// 详情态：读关联账目（含已软删的，D22）。
    private func loadRecordedEntry(_ entryID: UUID?, environment: AppEnvironment) throws {
        guard let entryID else {
            recordedText = nil
            linkedEntryDeleted = false
            return
        }
        guard let entry = try environment.readContext
            .fetch(QueryDescriptors.entry(id: entryID))
            .first else {
            // 账目被硬删了：仍然要显示「已记账」这件事，只是没有金额可看
            recordedText = nil
            linkedEntryDeleted = true
            return
        }
        linkedEntryDeleted = entry.deletedAt != nil
        recordedText = Money(cents: entry.amount).formatted()
    }

    // MARK: - 派生

    /// 是否填了预计金额。
    var hasEstimatedAmount: Bool {
        !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 预计金额（分）；未填或格式非法为 nil。
    var estimatedAmount: Money? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AmountInput.money(from: trimmed)
    }

    /// 详情态：预计金额文案（`nil` = 未记录）。
    var estimatedText: String? {
        guard hasEstimatedAmount, let amount = estimatedAmount else { return nil }
        return amount.formatted()
    }

    /// 重复规则描述。
    var repeatText: String {
        guard repeatRule != .none else { return "不重复" }
        return repeatRule.displayName + (repeatInterval > 1 ? "（每 \(repeatInterval) 次）" : "")
    }

    /// 截止文案。
    var dueText: String {
        guard hasDueDate else { return "无日期" }
        guard hasDueTime else { return dueDay.displayString }
        return "\(dueDay.displayString) \(TodoEditorViewModel.timeText(dueTimeMinutes))"
    }

    /// 是否可以保存。
    var canSave: Bool {
        validationMessage() == nil
    }

    /// 保存按钮禁用时的一句话解释（`nil` = 可以保存）。
    var saveDisabledReason: String? {
        validationMessage()
    }

    // MARK: - 校验

    /// 逐条检查并返回第一条错误（`nil` = 没问题）。
    func validationMessage() -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "请填写待办标题" }
        if trimmed.count > TodoEditorViewModel.titleLimit { return "标题最多 60 个字" }
        if note.count > TodoEditorViewModel.noteLimit { return "备注最多 500 个字" }
        if !TodoEditorViewModel.repeatIntervalRange.contains(repeatInterval) {
            return "重复间隔需要在 1 到 366 之间"
        }
        // 没勾「有花销」时，金额这块整块不参与校验（连格式都不看）
        if hasExpense, hasEstimatedAmount {
            guard let amount = estimatedAmount else { return "金额格式不对" }
            if amount.cents < 0 { return "金额不能为负" }
        }
        return nil
    }

    // MARK: - 交互

    func select(categoryID newID: UUID) {
        guard categories.contains(where: { $0.id == newID }) else { return }
        categoryID = newID
        errorMessage = nil
    }

    func select(accountID newID: UUID) {
        guard accounts.contains(where: { $0.id == newID }) else { return }
        accountID = newID
        errorMessage = nil
    }

    /// 关闭「有花销」时把金额/分类/账户一起清掉，避免留下半截数据。
    func setHasExpense(_ enabled: Bool) {
        hasExpense = enabled
        if !enabled {
            amountText = ""
            categoryID = nil
            accountID = nil
        } else {
            applyCreateDefaultsIfNeeded()
        }
        errorMessage = nil
    }

    private func applyCreateDefaultsIfNeeded() {
        if categoryID == nil { categoryID = categories.first?.id }
        if accountID == nil { accountID = accounts.first?.id }
    }

    func select(repeatRule newRule: RepeatRule) {
        repeatRule = newRule
        if newRule == .none { repeatInterval = 1 }
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 保存

    /// 保存（新建或编辑）。
    ///
    /// - Returns: 成功时的结果；失败返回 nil 并写入 `errorMessage`。
    @discardableResult
    func save() -> TodoSaveOutcome? {
        errorMessage = nil
        guard let environment else {
            errorMessage = "数据还没准备好，请稍后再试"
            return nil
        }
        if let message = validationMessage() {
            errorMessage = message
            return nil
        }

        // 有花销但没填金额 → 预计金额留空（hasEstimatedAmount = false，而不是 0）
        let estimatedCents: Int64 = hasExpense ? (estimatedAmount?.cents ?? 0) : 0
        let hasEstimated: Bool = hasExpense && hasEstimatedAmount
        let dueKey: Int32 = hasDueDate ? dueDay.key : 0
        let dueTime: Int32 = (hasDueDate && hasDueTime) ? dueTimeMinutes : -1
        let reminderKey: Int32 = reminderEnabled ? reminderDay.key : 0
        let reminderTime: Int32 = reminderEnabled ? reminderMinutes : -1

        do {
            switch mode {
            case .create:
                let draft = TodoDraft(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    note: note,
                    dueDay: dueKey,
                    dueTimeMinutes: dueTime,
                    hasExpense: hasExpense,
                    hasEstimatedAmount: hasEstimated,
                    estimatedAmount: estimatedCents,
                    priority: priority,
                    repeatRule: repeatRule,
                    repeatInterval: repeatRule == .none ? 1 : repeatInterval,
                    categoryID: hasExpense ? categoryID : nil,
                    accountID: hasExpense ? accountID : nil,
                    reminderDay: reminderKey,
                    reminderMinutes: reminderTime
                )
                let id = try environment.todo.create(draft)
                return TodoSaveOutcome(todoID: id, isNew: true)

            case .edit(let id):
                var changes = TodoChanges()
                changes.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.note = note
                changes.dueDay = dueKey
                changes.dueTimeMinutes = dueTime
                changes.hasExpense = hasExpense
                changes.hasEstimatedAmount = hasEstimated
                // R-TODO-6：这里改的是"计划"。实际花掉的金额只存在于账目里，
                // `confirmCompletion` 从不回写 `estimatedAmount`，本方法也不碰它。
                changes.estimatedAmount = estimatedCents
                changes.priority = priority
                changes.repeatRule = repeatRule
                changes.repeatInterval = repeatRule == .none ? 1 : repeatInterval
                changes.categoryID = hasExpense ? categoryID : nil
                changes.accountID = hasExpense ? accountID : nil
                changes.reminderDay = reminderKey
                changes.reminderMinutes = reminderTime

                try environment.todo.update(id: id, changing: changes)
                return TodoSaveOutcome(todoID: id, isNew: false)
            }
        } catch let error as TodoError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)。内容还在，改一下再点保存。"
            return nil
        }
    }

    /// 撤销完成（详情态）。
    @discardableResult
    func reopen(keepEntry: Bool) -> String? {
        guard let environment, let id = mode.todoID else { return nil }
        do {
            try environment.todo.reopen(id: id, keepEntry: keepEntry)
            status = .open
            isDone = false
            linkedEntryID = nil
            recordedText = nil
            linkedEntryDeleted = false
            return keepEntry ? "已撤销完成，账目保留" : "已撤销完成，账目已删除"
        } catch let error as TodoError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "撤销没成功：\(error.localizedDescription)。下拉刷新可以看到最新状态。"
            return nil
        }
    }

    // MARK: - 删除

    /// 「删除此次及以后」：删掉这一条，并且不再生成下一期。
    ///
    /// **非重复待办也走这个方法**（服务层对非重复就是硬删、不 spawn，
    /// `receipt.stoppedSeries == false`）—— 详情页不再保留一条"裸删"捷径。
    /// 两条通路做的是同一件事，早晚只会有人改其中一条，留着就是埋雷。
    ///
    /// 走 `environment.todo.deleteAndStopSeries(id:)`，**本方法不自己拼凭据**：
    /// 凭据里的 `snapshot` 必须由服务层在删除前拍下，这里再拍一次就会漏掉
    /// 服务层在删除过程中改动的字段。
    ///
    /// - Returns: `.deleted` + 撤销凭据；失败返回 nil 并写入 `errorMessage`。
    @discardableResult
    func deleteAndStopSeries() -> TodoEditorResult? {
        guard let environment, let id = mode.todoID else { return nil }
        do {
            let receipt = try environment.todo.deleteAndStopSeries(id: id)
            return .deleted(message: deletionMessage(for: receipt), receipt: receipt)
        } catch {
            errorMessage = "删除没成功：\(error.localizedDescription)。下拉刷新后重试。"
            return nil
        }
    }

    /// 「删除这一期」：删掉这一条，系列继续（服务层会顺带生成下一期）。
    ///
    /// - Returns: `.deleted` + 撤销凭据（`spawnedNextID` 指向新生成的那一期）；失败返回 nil。
    @discardableResult
    func deleteCurrentOccurrence() -> TodoEditorResult? {
        guard let environment, let id = mode.todoID else { return nil }
        do {
            let receipt = try environment.todo.deleteCurrentOccurrence(id: id)
            return .deleted(message: "已跳过这一期", receipt: receipt)
        } catch {
            errorMessage = "删除没成功：\(error.localizedDescription)。下拉刷新后重试。"
            return nil
        }
    }

    /// 删除成功的 Toast 文案。
    ///
    /// **必须先判 `isDone`、再判 `stoppedSeries`**，顺序不能反：一条**已完成**的重复待办
    /// `stoppedSeries` 也是 `true`（它确实属于一个重复系列），但它的下一期在
    /// `complete` 时就已经生成了 —— 删掉这条历史记录**并不会让系列停下来**。
    /// 反过来先判 `stoppedSeries`，用户点了「删除这条记录」却收到「已停止重复」，
    /// 而系列明明还在，这是最糟的一种"文案比事实更严重"。
    ///
    /// 已完成且**不重复**的仍说「已删除待办」：与列表页 `delete(id:)` 的文案同口径，
    /// 这一例本来就没有歧义，不需要跟着弹层标题一起改。
    private func deletionMessage(for receipt: TodoDeletionReceipt) -> String {
        if isDone {
            return isRepeating ? "已删除记录" : "已删除待办"
        }
        return receipt.stoppedSeries ? "已停止重复" : "已删除待办"
    }

    // MARK: - 工具

    /// 截止时刻（`DatePicker` 绑这个；只取时/分，日期部分无意义）。
    var dueTimeDate: Date {
        get { TodoEditorViewModel.date(fromMinutes: dueTimeMinutes) }
        set { dueTimeMinutes = TodoEditorViewModel.minutes(from: newValue) }
    }

    /// 提醒时刻（同上）。
    var reminderTimeDate: Date {
        get { TodoEditorViewModel.date(fromMinutes: reminderMinutes) }
        set { reminderMinutes = TodoEditorViewModel.minutes(from: newValue) }
    }

    /// 分钟数 → 今天的那一时刻（`DatePicker` 需要 `Date`）。
    static func date(fromMinutes minutes: Int32) -> Date {
        let clamped = min(max(Int(minutes), 0), 1439)
        let start = Calendar.current.startOfDay(for: Date())
        return start.addingTimeInterval(TimeInterval(clamped * 60))
    }

    /// `Date` → 分钟数。
    static func minutes(from date: Date) -> Int32 {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return Int32(min(max(hour * 60 + minute, 0), 1439))
    }

    /// 分钟数 → 「09:30」。
    static func timeText(_ minutes: Int32) -> String {
        let clamped = min(max(Int(minutes), 0), 1439)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
