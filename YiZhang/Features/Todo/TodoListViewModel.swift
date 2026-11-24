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

    /// 展示用分组（已完成按折叠状态过滤）。
    var visibleGroups: [TodoGroupModel] {
        groups.filter { group in
            !(group.kind == .done && isCompletedCollapsed)
        }
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
            linkedEntryDeleted: deletedEntry
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
