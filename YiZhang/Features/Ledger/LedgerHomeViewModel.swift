//
//  LedgerHomeViewModel.swift
//  一账 / Features / Ledger
//
//  职责：账本首页的全部状态（T08）——按月分组、月度概览、较上月对比、今日速览、筛选。
//
//  这是用户 90% 时间停留的一屏，因此数据组织方式比"取到就渲染"讲究三件事：
//  ① **一次查询、内存分组**：单月账目量级 ≤ 400 条（PRD 假设），
//     一次 fetch 后按 `occurredDay` 分组成 `DayGroup`，比"每天一次 fetch"少几百次 IO；
//  ② **分组头合计与概览卡必须同源**：两者都从同一批 `entries` 累加，
//     绝不出现"概览卡说 ¥3,482、分组头加起来 ¥3,401"这种自相矛盾（验收项之一）；
//  ③ **筛选在内存里做**：为 6 个维度的组合写 `#Predicate` 会有 2^6 种分支，
//     而数据量小到内存过滤的代价可以忽略（这也是 `QueryDescriptors` 刻意不提供分类谓词的原因）。
//
//  今日速览的待办数据**直接走 `QueryDescriptors`**，不依赖尚不存在的 `TodoService`（T15）：
//  速览只需要"今天有几件待办"，为它提前发明一个服务接口，T15 落地时必然要返工。
//

import Foundation
import Observation
import SwiftData

// MARK: - 行模型

/// 首页一行的值类型（View 不持有 `@Model`，避免上下文保存时的隐式变化）。
struct EntryRowModel: Identifiable, Hashable, Sendable {

    let id: UUID
    let type: EntryType
    let amount: Money
    let note: String
    /// 分类名（转账为「转账」）。
    let categoryName: String
    let iconName: String
    let colorHex: String
    /// 付款账户名（转账为转出账户）。
    let accountName: String
    /// 转入账户名（仅转账）。
    let toAccountName: String?
    let source: EntrySource
    let day: DateOnly
    let createdAt: Date
    let categoryID: UUID?
    let accountID: UUID?
    let toAccountID: UUID?

    /// 从模型拍成值类型。
    init(entry: LedgerEntry) {
        id = entry.id
        type = entry.type
        amount = entry.amountMoney
        note = entry.note
        day = entry.occurredDate
        source = entry.source
        createdAt = entry.createdAt
        categoryID = entry.category?.id
        accountID = entry.account?.id
        toAccountID = entry.toAccount?.id
        accountName = entry.account?.displayName ?? "账户已删除"
        toAccountName = entry.toAccount?.displayName

        if entry.isTransfer {
            categoryName = "转账"
            iconName = "arrow.left.arrow.right"
            colorHex = PresetCatalog.fallbackColorHex
        } else if let category = entry.category {
            categoryName = category.displayName
            iconName = category.displayIconName
            colorHex = category.colorHex
        } else {
            // 分类被删且没归档到「其他」的极端情况：给一个中性兜底，绝不渲染空白
            categoryName = "未分类"
            iconName = "questionmark.circle"
            colorHex = PresetCatalog.fallbackColorHex
        }
    }

    /// 测试/预览用。
    init(
        id: UUID = UUID(),
        type: EntryType = .expense,
        amount: Money,
        note: String = "",
        categoryName: String = "餐饮",
        iconName: String = "fork.knife",
        colorHex: String = "#C0392B",
        accountName: String = "微信",
        toAccountName: String? = nil,
        source: EntrySource = .manual,
        day: DateOnly,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        toAccountID: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.amount = amount
        self.note = note
        self.categoryName = categoryName
        self.iconName = iconName
        self.colorHex = colorHex
        self.accountName = accountName
        self.toAccountName = toAccountName
        self.source = source
        self.day = day
        self.createdAt = createdAt
        self.categoryID = categoryID
        self.accountID = accountID
        self.toAccountID = toAccountID
    }

    /// 金额色调。
    var tone: MoneyText.Tone { MoneyText.Tone(type: type) }
}

// MARK: - 分组

/// 一天的账目分组（PRD 3.3 分组头：`11月20日 周四 · 支出 ¥86.00 收入 ¥0`）。
struct DayGroup: Identifiable, Hashable, Sendable {

    let day: DateOnly
    let rows: [EntryRowModel]
    /// 当天支出合计（转账不计）。
    let expense: Money
    /// 当天收入合计。
    let income: Money

    var id: Int32 { day.key }

    /// 「11月20日 周四」
    var headerTitle: String { "\(day.month)月\(day.day)日 \(day.weekdayName)" }

    /// 「支出 ¥86.00 收入 ¥0」——收入为 0 时也显示，避免用户以为漏算。
    var detailText: String {
        "支出 \(expense.formatted()) 收入 \(income.formatted())"
    }

    /// 从若干行算出当天合计（转账既不进支出也不进收入）。
    static func make(day: DateOnly, rows: [EntryRowModel]) -> DayGroup {
        var expenseCents: Int64 = 0
        var incomeCents: Int64 = 0
        for row in rows {
            switch row.type {
            case .expense: expenseCents += row.amount.cents
            case .income: incomeCents += row.amount.cents
            case .transfer: continue
            }
        }
        return DayGroup(
            day: day,
            rows: rows,
            expense: Money(cents: expenseCents),
            income: Money(cents: incomeCents)
        )
    }
}

// MARK: - 今日速览

/// 「今日速览」条：今天还有几件待办、7 天内有几笔订阅要扣。
struct GlanceModel: Hashable, Sendable {

    /// 今天到期或已逾期的未完成待办数。
    let todoCount: Int
    /// 7 天内要扣的订阅笔数。
    let subscriptionCount: Int
    /// 7 天内要扣的金额合计。
    let subscriptionTotal: Money

    static let empty = GlanceModel(todoCount: 0, subscriptionCount: 0, subscriptionTotal: .zero)

    /// 两项都为空时整条隐藏（R-LIST-1：没内容就不要留一块空白）。
    var isEmpty: Bool { todoCount == 0 && subscriptionCount == 0 }
}

// MARK: - 较上月对比

/// 支出与上月的对比。
struct ExpenseComparison: Hashable, Sendable {

    /// 变化方向。
    enum Direction: Hashable, Sendable {
        case increase
        case decrease
        case flat
        /// 上月没有支出，无法计算百分比
        case unavailable
    }

    let direction: Direction
    /// 百分比绝对值（千分位：`124` = 12.4%）。
    let magnitudeThousandths: Int64

    static let unavailable = ExpenseComparison(direction: .unavailable, magnitudeThousandths: 0)

    /// 文本：「较上月 ▲12.4%」/「较上月 ▼8.1%」/「与上月持平」/「上月没有支出」。
    var text: String {
        switch direction {
        case .unavailable: return "上月没有支出"
        case .flat: return "与上月持平"
        case .increase: return "较上月 ▲\(ExpenseComparison.percentText(magnitudeThousandths))"
        case .decrease: return "较上月 ▼\(ExpenseComparison.percentText(magnitudeThousandths))"
        }
    }

    /// 千分位 → 「12.4」（纯整数运算，不经过 Double）。
    ///
    /// 超过 999% 直接封顶成「999%+」：上月只有 ¥25 而本月 ¥2,985 时真实增幅是 11,842%，
    /// 把五位数字印在卡片上既占位又没有信息量（用户只需要知道"涨得非常多"）。
    static func percentText(_ thousandths: Int64) -> String {
        let value = abs(thousandths)
        guard value < 9_990 else { return "999%+" }
        return "\(value / 10).\(value % 10)%"
    }

    /// 计算对比。
    ///
    /// - Parameters:
    ///   - current: 本月支出（分）。
    ///   - previous: 上月支出（分）。
    /// - Returns: 对比结果。**上月为 0 时返回 `.unavailable`**——
    ///   除以 0 会得到 `inf`，直接显示「+∞%」比不显示更糟。
    static func make(current: Money, previous: Money) -> ExpenseComparison {
        guard previous.cents > 0 else {
            return current.cents > 0 ? .unavailable : ExpenseComparison(direction: .flat, magnitudeThousandths: 0)
        }
        let deltaCents = current.cents - previous.cents
        // 与上月完全相等：明确说"持平"，不要显示 ▲0.0%
        guard deltaCents != 0 else {
            return ExpenseComparison(direction: .flat, magnitudeThousandths: 0)
        }
        let thousandths = deltaCents * 1_000 / previous.cents
        let direction: Direction = deltaCents > 0 ? .increase : .decrease
        return ExpenseComparison(direction: direction, magnitudeThousandths: abs(thousandths))
    }
}

// MARK: - ViewModel

/// 账本首页状态机。
@Observable
@MainActor
final class LedgerHomeViewModel {

    // MARK: - 时间

    /// 今天（`load()` 会刷新；测试注入固定值后不再调 `refreshToday()`）。
    private(set) var today: DateOnly

    /// 当前浏览月份 `yyyyMM`。
    private(set) var monthKey: Int32

    // MARK: - 输出

    /// 当前页显示的日分组（已应用筛选）。
    private(set) var groups: [DayGroup] = []
    /// 未筛选的全部日分组（筛选时用它在内存里筛，避免重复 fetch）。
    private(set) var allGroups: [DayGroup] = []
    /// 本月合计。
    private(set) var overview: MonthSummary = .zero
    /// 上月合计（算百分比用）。
    private(set) var previousOverview: MonthSummary = .zero
    /// 与上月的支出对比。
    private(set) var comparison: ExpenseComparison = .unavailable
    /// 今日速览。
    private(set) var glance: GlanceModel = .empty

    /// 筛选条件。
    private(set) var filter: EntryFilter = EntryFilter()

    /// 筛选面板用的分类 / 账户清单。
    private(set) var categoryOptions: [CategoryOption] = []
    private(set) var accountOptions: [AccountOption] = []

    private(set) var errorMessage: String?
    private(set) var isLoading = false

    /// 本月账目笔数（未筛选）。
    var entryCount: Int { allGroups.reduce(0) { $0 + $1.rows.count } }

    /// 是否有任何账目（用来区分"空态"与"筛选无结果"）。
    var hasAnyEntry: Bool { !allGroups.isEmpty }

    /// 是否正在筛选。
    var isFiltering: Bool { filter.isActive }

    /// 筛选后一笔都没有（与"本月没记账"是两件事，文案不同）。
    var isFilteredEmpty: Bool { filter.isActive && groups.isEmpty && hasAnyEntry }

    /// 顶部 chips。
    var filterChips: [EntryFilter.Chip] { filter.chips() }

    /// 月份标题「2026年11月」。
    var monthTitle: String {
        "\(monthKey / 100)年\(monthKey % 100)月"
    }

    /// 当前月份是否是本月（本月不能再往后翻）。
    var isCurrentMonth: Bool { monthKey >= today.monthKey }

    /// 是否可以往后翻（不允许超过当前月）。
    var canGoNextMonth: Bool { monthKey < today.monthKey }

    // MARK: - 依赖

    private var environment: AppEnvironment?

    // MARK: - 初始化

    /// - Parameters:
    ///   - today: 今天。
    ///   - monthKey: 初始浏览月份；`nil` 表示取今天的月份。
    init(today: DateOnly = DateOnly(Date()), monthKey: Int32? = nil) {
        self.today = today
        let resolved = monthKey ?? today.monthKey
        self.monthKey = resolved > 0 ? resolved : today.monthKey
    }

    /// 注入依赖并首次加载。
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    /// 刷新"今天"（App 从后台回来时日期可能已经变了）。
    func refreshToday() {
        let newToday = DateOnly(Date())
        guard newToday != today else { return }
        today = newToday
    }

    // MARK: - 加载

    /// 读取本月 + 上月的账目、订阅快照与今日待办，重建全部分组与汇总。
    func load() {
        guard let environment else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let entries = try environment.readContext.fetch(QueryDescriptors.monthEntries(monthKey))
            let previousEntries = try environment.readContext.fetch(
                QueryDescriptors.monthEntries(previousMonthKey)
            )

            let rows = entries.map(EntryRowModel.init(entry:))
            allGroups = LedgerHomeViewModel.makeGroups(rows: rows)
            overview = LedgerHomeViewModel.summarize(rows)
            previousOverview = LedgerHomeViewModel.summarize(
                previousEntries.map(EntryRowModel.init(entry:))
            )
            comparison = ExpenseComparison.make(
                current: overview.expense,
                previous: previousOverview.expense
            )

            glance = makeGlance(environment: environment)
            categoryOptions = loadCategoryOptions(environment: environment)
            accountOptions = loadAccountOptions(environment: environment)

            applyFilterToGroups()
            errorMessage = nil
        } catch {
            allGroups = []
            groups = []
            overview = .zero
            previousOverview = .zero
            comparison = .unavailable
            glance = .empty
            errorMessage = "账目读取失败：\(error.localizedDescription)。下拉可以重新加载。"
        }
    }

    /// 下拉刷新：先强制扫一次订阅（用户明确表达了"我现在想看最新的"），再重算。
    func refresh() async {
        guard let environment else { return }
        refreshToday()
        _ = environment.sweep.sweep(today: today, force: true)
        load()
    }

    // MARK: - 月份切换

    /// 上一月。
    func goPreviousMonth() {
        guard let previous = LedgerHomeViewModel.previousMonth(of: monthKey) else { return }
        monthKey = previous
        load()
    }

    /// 下一月（不允许超过当前月）。
    func goNextMonth() {
        guard canGoNextMonth, let next = LedgerHomeViewModel.nextMonth(of: monthKey) else { return }
        monthKey = next
        load()
    }

    /// 回到本月。
    func goToCurrentMonth() {
        guard monthKey != today.monthKey else { return }
        monthKey = today.monthKey
        load()
    }

    /// 跳到指定月份。
    ///
    /// 用途：刚记的那笔账可能不在当前浏览的月份里（比如翻到了 10 月却记了今天的账），
    /// 保存成功后必须跳过去，否则用户看到的是"记了一笔但列表没变"。
    func goToMonth(_ key: Int32) {
        guard key > 0, key != monthKey else { return }
        monthKey = key
        load()
    }

    // MARK: - 筛选

    /// 应用筛选条件。
    func applyFilter(_ newFilter: EntryFilter) {
        filter = newFilter
        applyFilterToGroups()
    }

    /// 清空全部筛选。
    func clearFilter() {
        guard filter.isActive else { return }
        filter.clearAll()
        applyFilterToGroups()
    }

    /// 移除某一个 chip。
    func removeChip(id: String) {
        filter.removeChip(id: id)
        applyFilterToGroups()
    }

    /// 关闭错误提示。
    func dismissError() {
        errorMessage = nil
    }

    /// 按当前 `filter` 重建 `groups`（纯内存操作，不触发 fetch）。
    private func applyFilterToGroups() {
        guard filter.isActive else {
            groups = allGroups
            return
        }
        let activeFilter = filter
        let referenceDay = today
        groups = allGroups.compactMap { group in
            let rows = group.rows.filter { activeFilter.matches($0, today: referenceDay) }
            guard !rows.isEmpty else { return nil }
            return DayGroup.make(day: group.day, rows: rows)
        }
    }

    // MARK: - 私有工具

    /// 上月月份键。
    var previousMonthKey: Int32 {
        LedgerHomeViewModel.previousMonth(of: monthKey) ?? monthKey
    }

    /// 上月键（1 月 → 上一年 12 月）。
    static func previousMonth(of monthKey: Int32) -> Int32? {
        let year = monthKey / 100
        let month = monthKey % 100
        guard monthKey > 0, (1...12).contains(month) else { return nil }
        if month == 1 {
            guard year > 1 else { return nil }
            return (year - 1) * 100 + 12
        }
        return year * 100 + (month - 1)
    }

    /// 下月键（12 月 → 下一年 1 月）。
    static func nextMonth(of monthKey: Int32) -> Int32? {
        let year = monthKey / 100
        let month = monthKey % 100
        guard monthKey > 0, (1...12).contains(month) else { return nil }
        if month == 12 { return (year + 1) * 100 + 1 }
        return year * 100 + (month + 1)
    }

    /// 行 → 日分组（保持"日期倒序、同一天按创建时间倒序"）。
    ///
    /// 输入已由 `QueryDescriptors.monthEntries` 排好序，这里只做稳定分组，
    /// 不再二次排序——一旦重排，`createdAt` 相同的两笔账顺序会在每次刷新时变化。
    static func makeGroups(rows: [EntryRowModel]) -> [DayGroup] {
        var order: [Int32] = []
        var buckets: [Int32: [EntryRowModel]] = [:]
        for row in rows {
            let key = row.day.key
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(row)
        }
        return order.compactMap { key in
            guard let rows = buckets[key], !rows.isEmpty else { return nil }
            return DayGroup.make(day: DateOnly(key: key), rows: rows)
        }
    }

    /// 月度合计（转账不计入收支）。
    static func summarize(_ rows: [EntryRowModel]) -> MonthSummary {
        var expenseCents: Int64 = 0
        var incomeCents: Int64 = 0
        for row in rows {
            switch row.type {
            case .expense: expenseCents += row.amount.cents
            case .income: incomeCents += row.amount.cents
            case .transfer: continue
            }
        }
        return MonthSummary(expense: Money(cents: expenseCents), income: Money(cents: incomeCents))
    }

    /// 今日速览：今天及逾期的未完成待办 + 7 天内要扣的订阅。
    private func makeGlance(environment: AppEnvironment) -> GlanceModel {
        let todoCount = (try? environment.readContext.fetchCount(
            QueryDescriptors.openTodos(dueOnOrBefore: today)
        )) ?? 0

        let snapshots = (try? environment.readContext
            .fetch(QueryDescriptors.allSubscriptions())
            .map(SubscriptionMapper.snapshot(of:))) ?? []
        let upcoming = SubscriptionOverview.upcoming(snapshots, today: today, within: 7)

        return GlanceModel(
            todoCount: todoCount,
            subscriptionCount: upcoming.count,
            subscriptionTotal: SubscriptionOverview.upcomingTotal(upcoming)
        )
    }

    private func loadCategoryOptions(environment: AppEnvironment) -> [CategoryOption] {
        let expense = (try? environment.readContext
            .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
            .map(CategoryOption.init)) ?? []
        let income = (try? environment.readContext
            .fetch(QueryDescriptors.categories(of: .income, includeHidden: false))
            .map(CategoryOption.init)) ?? []
        return expense + income
    }

    private func loadAccountOptions(environment: AppEnvironment) -> [AccountOption] {
        (try? environment.readContext
            .fetch(QueryDescriptors.accounts(includeArchived: false))
            .map(AccountOption.init)) ?? []
    }
}
