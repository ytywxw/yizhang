//
//  StatisticsViewModel.swift
//  一账 / Features / Statistics
//
//  职责：统计页的调度（T19）——取数 → 调 `StatisticsCalculator` → 装态。
//
//  **本类不做任何算术**：占比、累计、补 0 全在纯函数里（可单测、口径唯一）。
//  ViewModel 只做三件事：① 从只读上下文取 `[LedgerLite]`；② 给分类 id 配上名字；
//  ③ 把用户的选择（范围 / 下钻）翻译成下一次取数。
//
//  性能口径：4000 条账目的一次 `load()` 必须在 80ms 内完成（含 SwiftData 读取）。
//  取数用 `QueryDescriptors.entries(in:)` 之外的**单次全量扫**：统计本来就要跨 6 个月，
//  分月查会变成 6 次 round trip；一次取回再在内存里分桶更快也更好测。
//

import Foundation
import Observation
import SwiftData

/// 统计页 ViewModel。
@Observable
@MainActor
final class StatisticsViewModel {

    // MARK: - 状态

    /// 顶部范围（本月 / 上月 / 本年）。
    var range: StatisticsRange = .thisMonth {
        didSet {
            guard oldValue != range else { return }
            reload()
        }
    }

    /// 顶部口径（支出 / 收入）：分类占比与累计趋势跟着它换一套数据。
    var metric: StatisticsMetric = .expense {
        didSet {
            guard oldValue != metric else { return }
            reload()
        }
    }

    private(set) var snapshot: StatisticsSnapshot = .empty()

    /// 同比 / 环比（V1.1 F-ACC-16）。本年档 `mom == nil`。
    private(set) var comparison: StatisticsComparison = .empty
    /// 对比用到的那三个区间（卡片上要写清"和哪一段比"）。
    private(set) var comparisonBounds: PeriodComparisonBounds = .empty
    /// 账户构成（已排序、已合并）。
    private(set) var accountShares: [AccountShare] = []
    /// 被合并进「其他」的账户 id（下钻时用来精确筛选，而不是"显示全部"）。
    private(set) var mergedAccountIDs: Set<UUID> = []

    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    /// 分类 id → 名称（图表与排行都要用）。
    private(set) var categoryNames: [UUID: String] = [:]
    /// 分类 id → 图标名。
    private(set) var categoryIcons: [UUID: String] = [:]
    /// 分类 id → 颜色。
    private(set) var categoryColors: [UUID: String] = [:]

    /// 账户 id → 名称（账户构成卡用）。
    private(set) var accountNames: [UUID: String] = [:]
    /// 已归档的账户 id（行尾灰字「已归档」）。
    ///
    /// 为什么单独存一个集合而不是"名称里加后缀"：
    /// 名称要能被下钻页复用（标题就是账户名），把状态揉进字符串会让筛选/去重全变成字符串比较。
    private(set) var archivedAccountIDs: Set<UUID> = []

    /// 折线图上被选中的日（1…31）；nil = 没选中。
    var selectedDay: Int?

    let today: DateOnly

    // MARK: - 依赖

    private var environment: AppEnvironment?

    /// 最近一次 `reload()` 的耗时（毫秒）——首帧预算的自测入口。
    private(set) var lastLoadMilliseconds: Double = 0
    /// 其中"从 SwiftData 取 4000 行并映射成 `LedgerLite`"的耗时（毫秒）。
    private(set) var lastFetchMilliseconds: Double = 0
    /// 其中"纯聚合"的耗时（毫秒）。这两个数和 `lastLoadMilliseconds` 一起
    /// 让"慢在数据库还是慢在算法"这个问题不必靠猜。
    private(set) var lastAggregateMilliseconds: Double = 0
    /// 最近一次参与聚合的记录数（性能报告用）。
    private(set) var loadedEntryCount: Int = 0

    // MARK: - 初始化

    init(today: DateOnly = DateOnly(Date())) {
        self.today = today
    }

    // MARK: - 加载

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        loadCategoryLookup(environment)
        loadAccountLookup(environment)
        reload()
    }

    /// 重新取数并重算。
    func reload() {
        guard let environment else { return }
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let entries = try loadEntries(environment)
            let afterFetch = CFAbsoluteTimeGetCurrent()
            snapshot = StatisticsCalculator.snapshot(
                entries,
                range: range,
                today: today,
                metric: metric
            )
            // 同比环比与账户构成跟 `snapshot` 用同一批 `entries`、同一档 `range`/`metric`，
            // 于是"两卡之和 == 合计"不靠约定，靠输入完全相同
            comparison = StatisticsComparison(
                StatisticsCalculator.comparison(
                    entries,
                    range: range,
                    metric: metric,
                    today: today
                )
            )
            comparisonBounds = StatisticsCalculator.comparisonBounds(range: range, today: today)
            let accounts = StatisticsCalculator.accountShares(
                entries,
                range: range,
                metric: metric,
                today: today
            )
            accountShares = accounts.shares
            mergedAccountIDs = accounts.mergedIDs
            let afterAggregate = CFAbsoluteTimeGetCurrent()
            loadedEntryCount = entries.count
            lastFetchMilliseconds = (afterFetch - started) * 1000
            lastAggregateMilliseconds = (afterAggregate - afterFetch) * 1000
            errorMessage = nil
        } catch {
            errorMessage = "统计数据读取失败：\(error.localizedDescription)。切一下时间范围可以重算。"
            snapshot = .empty(range: range, metric: metric)
            comparison = .empty
            comparisonBounds = .empty
            accountShares = []
            mergedAccountIDs = []
            loadedEntryCount = 0
        }
        lastLoadMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        isLoaded = true
    }

    /// 下拉刷新。
    func refresh() async {
        reload()
    }

    /// 分类名称查表（只做一次；分类很少变）。
    ///
    /// **支出与收入两类都要取**：切到「收入」口径时如果只查了支出分类，
    /// 收入的每一块都会退化成「未分类 + 灰色」——图上看着像"没分类"，
    /// 实际上用户明明分好了类（实测就是这么发现的）。
    private func loadCategoryLookup(_ environment: AppEnvironment) {
        do {
            let expenseCategories = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .expense, includeHidden: true))
            let incomeCategories = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .income, includeHidden: true))
            let categories = expenseCategories + incomeCategories
            var names: [UUID: String] = [:]
            var icons: [UUID: String] = [:]
            var colors: [UUID: String] = [:]
            for category in categories {
                names[category.id] = category.name
                icons[category.id] = category.iconName
                colors[category.id] = category.colorHex
            }
            categoryNames = names
            categoryIcons = icons
            categoryColors = colors
        } catch {
            // 查表失败不该挡住图表：名称会退化成「未分类」
            categoryNames = [:]
            categoryIcons = [:]
            categoryColors = [:]
        }
    }

    /// 账户名称 / 归档状态查表（只做一次；账户很少变）。
    ///
    /// **必须含归档账户**：本档有账目的归档账户仍要显示（行尾标「已归档」），
    /// 本档没有账目的归档账户自然不会有桶，不需要额外过滤——
    /// 用 `includeArchived: false` 会让"上个月还有一笔、这个月归档了"的账户整个消失，
    /// 用户会以为那笔账丢了。
    private func loadAccountLookup(_ environment: AppEnvironment) {
        do {
            let accounts = try environment.readContext.fetch(QueryDescriptors.accounts())
            var names: [UUID: String] = [:]
            var archived = Set<UUID>()
            for account in accounts {
                names[account.id] = account.name
                if account.isArchived { archived.insert(account.id) }
            }
            accountNames = names
            archivedAccountIDs = archived
        } catch {
            // 查表失败不该挡住图表：名称会退化成「已删除账户」，归档标记会消失
            accountNames = [:]
            archivedAccountIDs = []
        }
    }

    /// 取全部账目 → `LedgerLite`。
    ///
    /// 只取需要的区间（近 6 个月 + 本年）会让本类出现第二套日期口径，
    /// 所以这里一次取全表：V1 的数据量（万级以内）下，内存拷贝远快于 6 次查询。
    private func loadEntries(_ environment: AppEnvironment) throws -> [LedgerLite] {
        let models = try environment.readContext.fetch(QueryDescriptors.allEntries())
        return models
            .filter { $0.deletedAt == nil }
            .map {
                LedgerLite(
                    id: $0.id,
                    amount: $0.amount,
                    typeRaw: $0.typeRaw,
                    occurredDay: $0.occurredDay,
                    categoryID: $0.category?.id,
                    accountID: $0.account?.id,
                    sourceRaw: $0.sourceRaw,
                    deletedAt: $0.deletedAt
                )
            }
    }

    // MARK: - 展示辅助

    /// 分类显示名（合并桶 → 「其他」，无分类 → 「未分类」）。
    func title(for share: CategoryShare) -> String {
        if share.isMerged { return "其他" }
        guard let id = share.categoryID else { return "未分类" }
        return categoryNames[id] ?? "未分类"
    }

    func iconName(for share: CategoryShare) -> String {
        guard let id = share.categoryID else { return "questionmark.circle" }
        return categoryIcons[id] ?? "circle"
    }

    func colorHex(for share: CategoryShare) -> String {
        guard let id = share.categoryID else { return "#9E9E9E" }
        return categoryColors[id] ?? "#9E9E9E"
    }

    // MARK: - 展示辅助（账户构成，V1.1 F-ACC-16）

    /// 账户行标题：合并桶 → 「其他」；无账户 → 「未知账户」；查不到名 → 「已删除账户」。
    ///
    /// 「查不到名」与「无账户」必须是两种文案：前者是"账户被删了但账目还在"（历史数据），
    /// 后者是"记账时就没选账户"。都写「未知账户」会让用户没法判断该不该去补一条账户。
    func title(for share: AccountShare) -> String {
        if share.isMerged { return "其他" }
        guard let id = share.accountID else { return "未知账户" }
        return accountNames[id] ?? "已删除账户"
    }

    /// 归档账户（行尾灰字「已归档」）；合并桶与无账户永远不是归档。
    func isArchived(_ share: AccountShare) -> Bool {
        guard let id = share.accountID else { return false }
        return archivedAccountIDs.contains(id)
    }

    /// 这一条能不能下钻。
    ///
    /// - 「其他」：`mergedIDs` 非空才可下钻（空集合下钻会筛出 0 条，比不可点更糟）。
    /// - 「未知账户」：**不可下钻**。`EntryFilter.accountIDs` 表达不了 `nil`，
    ///   硬凑一个空集合会被判成"不过滤"，结果筛出全部账目——那是在撒谎。
    /// - 真实账户：可下钻。
    func canDrill(into share: AccountShare) -> Bool {
        if share.isMerged { return !mergedAccountIDs.isEmpty }
        return share.accountID != nil
    }

    /// 下钻要带的账户 id 集合。
    func drillAccountIDs(for share: AccountShare) -> Set<UUID> {
        if share.isMerged { return mergedAccountIDs }
        guard let id = share.accountID else { return [] }
        return [id]
    }

    // MARK: - 展示辅助（同比环比）

    /// 对比卡的副标题：「本月至今 · 与去年同月、上月同期比」。
    ///
    /// 这句话不是装饰：卡片上有两个 chip，用户必须一眼看出"和哪两段比"，
    /// 否则会拿去年整月的心智去读一个"去年同月 1–20 日"的数字。
    var comparisonSubtitle: String {
        let current = ComparisonCopy.currentCaption(range)
        let yoy = ComparisonCopy.baselineCaption(slot: .yearOverYear, range: range)
        switch range {
        case .thisYear:
            // 本年档没有环比（任务书 §2），副标题也不能提"环比"
            return "\(current) · 与\(yoy)比"
        case .thisMonth, .lastMonth:
            let mom = ComparisonCopy.baselineCaption(slot: .monthOverMonth, range: range)
            return "\(current) · 与\(yoy)、\(mom)比"
        }
    }

    /// 对比卡是不是整张空（当期与两个基线都没有金额）。
    ///
    /// 只在**全都为 0** 时算空：当期 0、基线有数时必须照常显示「¥0.00 ▼100%」——
    /// 那是"这个月一分钱没花"，是一个有信息量的结论，不能藏进空态。
    var isComparisonEmpty: Bool {
        guard comparison.current.cents == 0 else { return false }
        if comparison.yoy.baseline.cents > 0 { return false }
        if let mom = comparison.mom, mom.baseline.cents > 0 { return false }
        return true
    }

    /// 折线图当前选中的点（跟随 `selectedDay`）。
    var selectedTrendPoint: DailyTrendPoint? {
        guard let selectedDay else { return nil }
        return snapshot.trend.first { $0.day == selectedDay }
    }

    /// 点折线：同一天再点一次取消选中。
    func select(day: Int) {
        selectedDay = (selectedDay == day) ? nil : day
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 文案

    /// 范围标题：「2026 年 11 月」/「2026 年」。
    var rangeTitle: String {
        switch range {
        case .thisMonth:
            return "\(today.year) 年 \(today.month) 月"
        case .lastMonth:
            let previous = StatisticsCalculator.previousMonthKey(of: today.monthKey)
            return "\(previous / 100) 年 \(previous % 100) 月"
        case .thisYear:
            return "\(today.year) 年"
        }
    }

    /// 近 6 个月对比的一句话（给 VoiceOver 用，也用于图表的可访问性摘要）。
    var monthlyComparisonSummary: String {
        let series = snapshot.monthlySeries
        guard let first = series.first, let last = series.last else { return "暂无月度数据" }
        guard first.expense.cents != last.expense.cents else {
            return "近 \(series.count) 个月支出基本持平，约 \(last.expense.formatted())"
        }
        let direction = last.expense.cents > first.expense.cents ? "增长" : "下降"
        return "近 \(series.count) 个月支出从 \(first.expense.formatted()) \(direction)到 \(last.expense.formatted())"
    }

    /// 分类占比的一句话。
    var categorySummary: String {
        let shares = snapshot.categoryShares
        guard let top = shares.first else { return "\(rangeTitle)还没有\(metric.displayName)记录" }
        return "\(metric.displayName)合计 \(snapshot.categoryTotal.formatted())，其中\(title(for: top))最多，占 \(top.percent)%"
    }

    /// 趋势的一句话。
    var trendSummary: String {
        let points = snapshot.trend
        guard let last = points.last else { return "暂无趋势数据" }
        let day = min(today.day, last.day)
        let current = points.first { $0.day == day }?.cumulative ?? .zero
        let previous = points.first { $0.day == day }?.previousCumulative
        let unit = metric.displayName
        if let previous {
            return "本月到 \(day) 日累计\(unit) \(current.formatted())，上月同期 \(previous.formatted())"
        }
        return "本月到 \(day) 日累计\(unit) \(current.formatted())"
    }
}
