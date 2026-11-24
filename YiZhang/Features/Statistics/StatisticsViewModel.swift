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
    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    /// 分类 id → 名称（图表与排行都要用）。
    private(set) var categoryNames: [UUID: String] = [:]
    /// 分类 id → 图标名。
    private(set) var categoryIcons: [UUID: String] = [:]
    /// 分类 id → 颜色。
    private(set) var categoryColors: [UUID: String] = [:]

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
            let afterAggregate = CFAbsoluteTimeGetCurrent()
            loadedEntryCount = entries.count
            lastFetchMilliseconds = (afterFetch - started) * 1000
            lastAggregateMilliseconds = (afterAggregate - afterFetch) * 1000
            errorMessage = nil
        } catch {
            errorMessage = "统计数据读取失败：\(error.localizedDescription)。切一下时间范围可以重算。"
            snapshot = .empty(range: range, metric: metric)
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
