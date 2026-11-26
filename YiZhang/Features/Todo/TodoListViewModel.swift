//
//  TodoListViewModel.swift
//  一账 / Features / Todo
//
//  职责：待办列表的分组、派生与全部行操作（T16）。
//
//  ## 五条刻意的设计
//
//  ① **分组是"五段"，顺序固定**：今天（含逾期）→ 本周 → 以后 → 无日期 → 已完成。
//     逾期不单独成组，而是留在「今天」里并标红——用户的脑子里"逾期"是"今天更该做的事"，
//     单独一组会让人以为它是另一类东西，而它恰恰是最该被看见的。
//  ② **订阅扣费是"只读派生"，不落库**（D4）：它来自 `SubscriptionOverview.upcoming(...)`，
//     每次 `load()` 重新算。绝不把它写成 `Todo`——否则订阅改一次金额就要去同步一批假待办，
//     而且"取消订阅"还得反过来清理，两套真相必然打架。
//  ③ **派生项不计入「今天要办 N 件」**（R-MIX-3）：那个数字是"用户要动手的事"，
//     订阅扣费是系统自动做的。混进去会让数字虚高，用户勾完了发现数字对不上。
//  ④ **已完成默认折叠**：列表的主语是"还没做的事"，已完成只提供"我刚才是不是勾错了"的核对入口。
//  ⑤ **下拽/取消关闭完成条必须回滚完成状态**：`complete()` 会先把状态置 done 再返回请求，
//     所以"用户改主意了"这条路径必须显式 `reopen`（见 `TodoCompletionSheetViewModel`）。
//  ⑥ **删除重复待办分两种语义，撤销靠"快照 + 原 id"而不是"再建一条新的"**（V1.1 / F-TODO-11）：
//     「删除这一期」= 跳过这一次（生成下一期），「删除此次及以后」= 系列到此为止。
//     两者的撤销都走 `TodoService.undoDeletion(_:)`，凭据里存着删之前的**全字段快照**，
//     撤回来的是同一条记录（同 id），账目的 `sourceRefID`、已排通知都对得上。
//

import Foundation
import Observation
import SwiftData

// MARK: - 分组

/// 待办分组。
enum TodoGroupKind: String, CaseIterable, Hashable, Sendable {
    case today
    case thisWeek
    case later
    case noDate
    case done

    var title: String {
        switch self {
        case .today: return "今天"
        case .thisWeek: return "本周"
        case .later: return "以后"
        case .noDate: return "无日期"
        case .done: return "已完成"
        }
    }

    /// 是否可折叠（目前只有「已完成」折叠）。
    var isCollapsible: Bool { self == .done }
}

// MARK: - 行模型

/// 一行待办。
struct TodoRowModel: Identifiable, Hashable, Sendable {

    let id: UUID
    let title: String
    /// 截止日文案：「截止 11月22日」/「逾期 11月20日」；无日期时为 nil。
    let dueText: String?
    /// 补充信息：「买菜 ¥86」/「买菜」；都没有时为 nil。
    let detailText: String?
    let dueDay: Int32
    let hasDueDate: Bool
    let isDone: Bool
    let isOverdue: Bool
    let hasExpense: Bool
    let priority: TodoPriority
    /// 是否由订阅派生（行右侧「来自订阅」徽章）。
    let isFromSubscription: Bool
    /// 是否已关联账目。
    let hasLinkedEntry: Bool
    /// 关联账目是否已被软删（D22：保留关联，渲染时判断）。
    let linkedEntryDeleted: Bool
    /// 这条待办是否属于一个重复系列（V1.1 / F-TODO-11）。
    ///
    /// **必须是 `var` 且带默认值**：写成 `let` 带默认值会被剔出 memberwise init，
    /// 于是所有既有调用点（含测试与 Preview）都会因为多出一个必填参数而编译失败；
    /// 放在声明区末尾 + `var` 才能让它成为"可选的新增参数"。
    ///
    /// 菜单据此决定出三项还是两项（见 `TodoRowView.menu`）。
    var isRepeating: Bool = false

    /// 副行整串。
    var subtitle: String {
        [dueText, detailText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 一个分组。
struct TodoGroupModel: Identifiable, Hashable, Sendable {

    let kind: TodoGroupKind
    let rows: [TodoRowModel]

    var id: String { kind.rawValue }
    var title: String { kind.title }
    var count: Int { rows.count }
    /// 分组头右侧的数字（「已完成」显示总数，其余显示条数）。
    var detailText: String { "\(count)" }
}

// MARK: - 删除反馈

/// 一次删除动作的反馈（UI 用它决定 Toast 文案与要不要挂「撤销」）。
///
/// 为什么不让 ViewModel 直接返回 `TodoDeletionReceipt`：凭据里含全字段快照，
/// View 拿到它只会误用（比如自己再拼一次撤销调用，绕过 3 秒窗口）。
/// View 需要的只有两件事：说什么、能不能撤销。
struct TodoDeletionFeedback: Hashable, Sendable {

    let message: String
    let canUndo: Bool
}

// MARK: - ViewModel

/// 待办列表状态机。
@Observable
@MainActor
final class TodoListViewModel {

    /// 订阅扣费分组的默认时间窗（天）。
    static let dueWindowDays = 7

    // MARK: 不可变

    let today: DateOnly

    // MARK: 可编辑状态

    /// 「已完成」是否收起（默认收起）。
    var isCompletedCollapsed = true
    /// 订阅扣费分组是否展开（默认收起）。
    private(set) var isDueSectionExpanded = false

    // MARK: 只读数据

    private(set) var groups: [TodoGroupModel] = []
    private(set) var dueItems: [SubscriptionOverview.DueItem] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    // MARK: 依赖

    private var environment: AppEnvironment?

    // MARK: 初始化

    init(today: DateOnly = DateOnly(Date())) {
        self.today = today
    }

    // MARK: - 加载

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    func load() {
        guard let environment else { return }
        do {
            let todos = try environment.todo.todos()
            let deletedLinkedIDs = try deletedLinkedEntryIDs(environment)
            groups = TodoListViewModel.makeGroups(
                todos: todos,
                today: today,
                deletedLinkedEntryIDs: deletedLinkedIDs
            )
            dueItems = try loadDueItems(environment)
            errorMessage = nil
        } catch {
            errorMessage = "读取待办失败：\(error.localizedDescription)。下拉可以重新加载。"
        }
        isLoaded = true
    }

    /// 刷新（下拉）。
    func refresh() async {
        load()
    }

    // MARK: - 计数

    /// 「今天要办 N 件」的 N。
    ///
    /// **只数今天分组里的待办**，不含订阅扣费派生项（R-MIX-3）：
    /// 那个数字回答的是"我要动手几件事"，而订阅扣费是系统自动做的，
    /// 混进去会让用户勾完所有待办后数字仍然不为零。
    var todayCount: Int {
        groups.first(where: { $0.kind == .today })?.count ?? 0
    }

    /// 今天分组里逾期的那几条（用于「其中 N 件已逾期」）。
    var overdueCount: Int {
        groups.first(where: { $0.kind == .today })?
            .rows.filter(\.isOverdue).count ?? 0
    }

    /// 是否有任何待办（空态判断用；订阅派生项不算）。
    var isEmpty: Bool {
        groups.isEmpty
    }

    /// 订阅扣费的合计金额。
    var dueTotal: Money {
        SubscriptionOverview.upcomingTotal(dueItems)
    }

    /// 展示用分组。**「已完成」永远不在这里。**
    ///
    /// 它由 `TodoListView.completedToggleBlock` 单独渲染（折叠头 + 展开后的行），
    /// 这一层再放一次就会让每条已完成记录被画两遍（V1.0 的既有缺陷）。
    /// 折叠状态只影响那张折叠头展不展开，不影响这里。
    var visibleGroups: [TodoGroupModel] {
        groups.filter { $0.kind != .done }
    }

    /// 已完成是否有内容（决定要不要画那张折叠头）。
    var completedGroup: TodoGroupModel? {
        groups.first(where: { $0.kind == .done })
    }

    // MARK: - 交互

    func toggleDueSection() {
        isDueSectionExpanded.toggle()
    }

    func toggleCompletedCollapsed() {
        isCompletedCollapsed.toggle()
    }

    func dismissError() {
        errorMessage = nil
    }

    /// 勾选完成（第一步）。
    ///
    /// - Returns: 需要弹确认条的请求；`nil` 表示"没有花销，已经直接完成"或失败。
    @discardableResult
    func complete(id: UUID) -> TodoCompletionRequest? {
        guard let environment else { return nil }
        do {
            let request = try environment.todo.complete(id: id)
            load()
            return request.needsConfirmation ? request : nil
        } catch let error as TodoError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "没标记成已完成：\(error.localizedDescription)。再点一次就行，不会重复记账。"
            return nil
        }
    }

    /// 撤销完成（R-TODO-7 的两个出口）。
    ///
    /// - Parameter keepEntry: `true` 保留关联账目，`false` 软删它。
    @discardableResult
    func reopen(id: UUID, keepEntry: Bool) -> String? {
        guard let environment else { return nil }
        do {
            try environment.todo.reopen(id: id, keepEntry: keepEntry)
            load()
            return keepEntry ? "已撤销完成，账目保留" : "已撤销完成，账目已删除"
        } catch let error as TodoError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "撤销没成功：\(error.localizedDescription)。下拉刷新可以看到最新状态。"
            return nil
        }
    }

    /// 删未完成待办（D23：真删，不做软删）。
    ///
    /// 这是**非重复**待办与「已完成」行的唯一删除入口（V1.0 行为，不挂撤销）。
    @discardableResult
    func delete(id: UUID) -> String? {
        guard let environment else { return nil }
        do {
            try environment.todo.delete(id: id)
            load()
            return "已删除待办"
        } catch {
            errorMessage = "删除没成功：\(error.localizedDescription)。下拉刷新后重试。"
            return nil
        }
    }

    // MARK: - 重复系列：删除 + 3 秒撤销（V1.1 / F-TODO-11）

    /// 撤销窗口时长（秒），与 Toast 的自动消失时长一致。
    ///
    /// 两处时长**必须同源**：Toast 先消失、窗口还在，用户会找不到撤销入口；
    /// 窗口先过期、Toast 还在，用户点了也没反应。所以这里用常量而不是各写一个 3。
    static let undoWindow: TimeInterval = 3

    /// 最近一次删除的撤销凭据（`nil` = 当前没有可撤销的删除）。
    private(set) var undoReceipt: TodoDeletionReceipt?

    /// 撤销入口的截止时刻。到点后即便 `undoReceipt` 还没来得及清，也必须拒绝撤销
    /// （`undoDeletion` 里会再校验一次 `Date() < undoExpiresAt`）。
    private(set) var undoExpiresAt: Date?

    /// 过期计时器。**连续两次删除必须先 cancel 旧的**，否则第一次的计时器到点会把
    /// 第二次刚拿到的凭据一起清掉 —— 撤销按钮点了没反应，且没有任何报错。
    private var undoExpiryTask: Task<Void, Never>?

    /// 当前是否还能撤销（UI 用它决定 Toast 上要不要挂「撤销」）。
    var canUndoDeletion: Bool {
        guard undoReceipt != nil, let expiresAt = undoExpiresAt else { return false }
        return Date() < expiresAt
    }

    /// 「删除此次及以后」：删掉这一期，且不再生成下一期。
    ///
    /// - Returns: Toast 用的文案 + 是否可撤销；`nil` 表示失败（错误已进 `errorMessage`）。
    @discardableResult
    func deleteAndStopSeries(id: UUID) async -> TodoDeletionFeedback? {
        guard let environment else { return nil }
        do {
            let receipt = try environment.todo.deleteAndStopSeries(id: id)
            beginUndoWindow(receipt)
            load()
            // 删掉一条待办 = pending 里少一条提醒；不重算就会在到期日提醒一件
            // 已经不存在的待办（收工标准 ⑪）
            await environment.rescheduleNotifications(today: today)
            return TodoDeletionFeedback(
                message: receipt.stoppedSeries ? "已删除，以后不会再重复" : "已删除待办",
                canUndo: true
            )
        } catch {
            errorMessage = "删除没成功：\(error.localizedDescription)。下拉刷新后重试。"
            return nil
        }
    }

    /// 「删除这一期」：跳过这一次，系列继续（内部会生成下一期）。
    @discardableResult
    func deleteCurrentOccurrence(id: UUID) async -> TodoDeletionFeedback? {
        guard let environment else { return nil }
        do {
            let receipt = try environment.todo.deleteCurrentOccurrence(id: id)
            beginUndoWindow(receipt)
            load()
            // 这一次没了、下一期来了：pending 必须整体换成新的那一期
            await environment.rescheduleNotifications(today: today)
            return TodoDeletionFeedback(message: "已跳过这一期", canUndo: true)
        } catch {
            errorMessage = "删除没成功：\(error.localizedDescription)。下拉刷新后重试。"
            return nil
        }
    }

    /// 把**外部**（详情页编辑器）产生的一次删除接进本页的撤销窗口。
    ///
    /// 为什么必须回传凭据、而不是让详情页自己弹一个带「撤销」的 Toast：
    /// 撤销窗口由本类的 `undoExpiryTask` **独占**（时长常量 `undoWindow` 也只有一个）。
    /// 详情页删完就 `dismiss()` 了，它没有位置挂这个窗口；在那边再开一个，
    /// 屏幕上就有两条独立的 3 秒计时器 —— 一条过期会把另一条的凭据一起清掉，
    /// 用户点了「撤销」没反应且没有任何报错。所以凭据必须回到这里。
    ///
    /// 内部**复用** `beginUndoWindow`（它会先 `cancel` 掉上一个计时器），
    /// 不复制第二份 3 秒逻辑。
    ///
    /// - Parameters:
    ///   - receipt: 编辑器删成功后交回来的凭据。
    ///   - message: 编辑器已经决定好的 Toast 文案（「已停止重复」等）。
    /// - Returns: Toast 用的文案 + 是否可撤销。
    @discardableResult
    func adoptUndo(_ receipt: TodoDeletionReceipt, message: String) -> TodoDeletionFeedback {
        beginUndoWindow(receipt)
        load()
        // 删掉一条待办 = pending 里少一条提醒（收工标准 ⑪），必须重算，
        // 否则到期日会为一条已经不存在的待办发通知。
        //
        // 这里**不能** `await`：调用点是 sheet 的同步关闭闭包，而撤销窗口的注册
        // 必须先于 `dismiss()` 完成 —— 晚一拍注册，Toast 上的「撤销」会有一瞬
        // 点了没反应（`canUndoDeletion` 还是 false）。所以重算作为独立任务派出去。
        if let environment {
            let today = today
            Task { await environment.rescheduleNotifications(today: today) }
        }
        return TodoDeletionFeedback(message: message, canUndo: true)
    }

    /// 撤销上一次删除（3 秒内有效）。
    ///
    /// - Returns: Toast 文案；`nil` 表示已过期或失败。
    @discardableResult
    func undoDeletion(now: Date = Date()) async -> String? {
        guard let environment else { return nil }
        guard let receipt = undoReceipt, let expiresAt = undoExpiresAt else { return nil }

        // 二次校验：计时器和点击之间存在竞态（计时器可能还没被调度到）
        guard now < expiresAt else {
            clearUndoWindow()
            return nil
        }

        do {
            // `TodoService.undoDeletion` 内部对"原 id 已存在"直接返回，
            // 所以连点两次「撤销」不会插出第二条
            try environment.todo.undoDeletion(receipt)
        } catch {
            // 写失败时**不关窗口**：凭据还在，用户还能再点一次（窗口未必已过期）。
            // 这里绝不先 clear 再 try —— 那样一次瞬时失败就永久丢掉撤销机会。
            errorMessage = "撤销没成功：\(error.localizedDescription)。下拉刷新可以看到最新状态。"
            return nil
        }

        clearUndoWindow()
        load()
        await environment.rescheduleNotifications(today: today)
        return receipt.stoppedSeries ? "已撤销，重复设置也回来了" : "已撤销删除"
    }

    /// 打开撤销窗口（并重启计时器）。
    private func beginUndoWindow(_ receipt: TodoDeletionReceipt, now: Date = Date()) {
        undoExpiryTask?.cancel()
        undoReceipt = receipt
        let expiresAt = now.addingTimeInterval(TodoListViewModel.undoWindow)
        undoExpiresAt = expiresAt
        // 弱引用：ViewModel 被释放后计时器不再持有它，也不需要谁去 cancel
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TodoListViewModel.undoWindow))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // 到点才清。**不比对 receipt 的 id**：`beginUndoWindow` 已经 cancel 了旧计时器，
            // 能走到这里的只可能是"当前这一次"的计时器。
            if let current = self.undoExpiresAt, Date() >= current {
                self.clearUndoWindow()
            }
        }
    }

    private func clearUndoWindow() {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        undoReceipt = nil
        undoExpiresAt = nil
    }

    /// 「移到明天」。
    @discardableResult
    func postponeToTomorrow(id: UUID) -> String? {
        guard let environment else { return nil }
        let tomorrow = today.adding(days: 1)
        do {
            try environment.todo.update(id: id, changing: TodoChanges(dueDay: tomorrow.key))
            load()
            return "已移到明天（\(tomorrow.displayString)）"
        } catch {
            errorMessage = "移动没成功：\(error.localizedDescription)。再做一次即可。"
            return nil
        }
    }

    // MARK: - 派生

    #if DEBUG
    /// 截图用：把第一条「未完成 + 带花销」的待办勾掉，返回它的完成请求。
    ///
    /// 只在无头截图时用（无法合成"点圆圈"这个手势）。**它会真的把待办置为 done**，
    /// 后续命运交给确认条：截图脚本会立刻退出，库里的值不影响验收外的任何用例。
    func completeFirstExpenseTodo() -> TodoCompletionRequest? {
        guard let environment else { return nil }
        guard let target = try? environment.todo.openTodos()
            .first(where: { $0.hasExpense }) else { return nil }
        return complete(id: target.id)
    }
    #endif

    /// 把待办分成五段。
    ///
    /// - Parameters:
    ///   - todos: 全部待办（含已完成）。
    ///   - today: 今天。
    ///   - deletedLinkedEntryIDs: 关联账目已被软删的待办集合（D22）。
    /// - Returns: 只包含**非空**的分组，顺序固定。
    static func makeGroups(
        todos: [Todo],
        today: DateOnly,
        deletedLinkedEntryIDs: Set<UUID> = []
    ) -> [TodoGroupModel] {
        var buckets: [TodoGroupKind: [TodoRowModel]] = [:]
        let weekEnd = today.adding(days: 6)

        for todo in todos {
            let kind = groupKind(of: todo, today: today, weekEnd: weekEnd)
            buckets[kind, default: []].append(
                makeRow(
                    todo,
                    today: today,
                    deletedEntry: todo.linkedEntryID.map { deletedLinkedEntryIDs.contains($0) } ?? false
                )
            )
        }

        return TodoGroupKind.allCases.compactMap { kind in
            guard let rows = buckets[kind], !rows.isEmpty else { return nil }
            return TodoGroupModel(kind: kind, rows: sort(rows, kind: kind))
        }
    }

    /// 单条待办归到哪一段。
    static func groupKind(of todo: Todo, today: DateOnly, weekEnd: DateOnly) -> TodoGroupKind {
        if todo.isDone { return .done }
        guard let due = todo.dueDate else { return .noDate }
        // 逾期与今天同组：逾期不是"另一类事"，而是"今天更该做的事"
        if due <= today { return .today }
        if due <= weekEnd { return .thisWeek }
        return .later
    }

    /// 组内排序：先按截止日，再按优先级（高在前），最后按创建时间，保证稳定。
    private static func sort(_ rows: [TodoRowModel], kind: TodoGroupKind) -> [TodoRowModel] {
        rows.sorted { lhs, rhs in
            if lhs.dueDay != rhs.dueDay {
                // 无日期（0）排最后
                if lhs.dueDay == 0 { return false }
                if rhs.dueDay == 0 { return true }
                return lhs.dueDay < rhs.dueDay
            }
            let lhsRank = priorityRank(lhs.priority)
            let rhsRank = priorityRank(rhs.priority)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func priorityRank(_ priority: TodoPriority) -> Int {
        switch priority {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    private static func makeRow(
        _ todo: Todo,
        today: DateOnly,
        deletedEntry: Bool
    ) -> TodoRowModel {
        let isOverdue = todo.isOverdue(on: today)
        var dueText: String?
        if let due = todo.dueDate {
            dueText = isOverdue ? "逾期 \(due.displayString)" : "截止 \(due.displayString)"
        }

        var detailParts: [String] = []
        if let categoryName = todo.category?.name, todo.hasExpense {
            detailParts.append(categoryName)
        }
        if todo.hasEstimatedAmount, todo.estimatedAmount > 0 {
            detailParts.append(Money(cents: todo.estimatedAmount).formatted())
        }

        return TodoRowModel(
            id: todo.id,
            title: todo.displayTitle,
            dueText: dueText,
            detailText: detailParts.isEmpty ? nil : detailParts.joined(separator: " "),
            dueDay: todo.dueDay,
            hasDueDate: todo.hasDueDate,
            isDone: todo.isDone,
            isOverdue: isOverdue,
            hasExpense: todo.hasExpense,
            priority: todo.priority,
            isFromSubscription: todo.sourceSubscription != nil,
            hasLinkedEntry: todo.hasLinkedEntry,
            linkedEntryDeleted: deletedEntry,
            isRepeating: todo.repeatRule != .none
        )
    }

    /// 订阅扣费派生项（不落库，D4）。
    private func loadDueItems(_ environment: AppEnvironment) throws -> [SubscriptionOverview.DueItem] {
        let subscriptions = try environment.readContext.fetch(QueryDescriptors.allSubscriptions())
        let snapshots = subscriptions.map { SubscriptionMapper.snapshot(of: $0) }
        return SubscriptionOverview.upcoming(
            snapshots,
            today: today,
            within: TodoListViewModel.dueWindowDays
        )
    }

    /// 关联账目 `id → 是否已软删`。
    ///
    /// 一次取全表（含软删）再过滤：V1 的数据量（万级以内）这个成本可以忽略，
    /// 换来的是"不用为每条待办单独查一次账目"。
    private func deletedLinkedEntryIDs(_ environment: AppEnvironment) throws -> Set<UUID> {
        let entries = try environment.readContext.fetch(QueryDescriptors.allEntries())
        return Set(entries.filter { $0.deletedAt != nil }.map(\.id))
    }
}
