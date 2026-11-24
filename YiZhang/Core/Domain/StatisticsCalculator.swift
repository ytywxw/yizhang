//
//  StatisticsCalculator.swift
//  一账 / Core / Domain
//
//  职责：统计页的全部聚合（T19）。
//
//  ## 为什么整块都是纯函数
//
//  ① **零数据库可单测**：输入 `[LedgerLite]`（7 个标量），输出值类型。
//     占比之和是不是 100%、空月有没有补 0、上月不足天数时折线到哪停，
//     这些都是容易错且不该用 UI 去验证的事。
//  ② **首帧预算**（4000 条 < 80ms）能被诚实测量：聚合里没有 SwiftData 的关系展开、
//     没有 `@Query`、没有主线程往返，只有几次线性扫描。
//  ③ ViewModel 只剩"取数 → 调用 → 装载"，没有一处算术，也就没有第二套口径。
//
//  ## 三条口径（写死在类型里，避免各处自己算）
//
//  - **转账不计入收支**：`type == .transfer` 一律跳过（与首页概览卡同一口径）。
//  - **软删记录不计入**：`isCountable` 已经判掉（`deletedAt == nil && amount > 0`）。
//  - **"本月/上月/本年"按自然月键算**，不用 `Date`/`Calendar`，跨时区不会漂。
//

import Foundation

// MARK: - 时间范围

/// 统计页顶部的时间范围（P0 只有三档）。
enum StatisticsRange: String, CaseIterable, Hashable, Sendable {
    case thisMonth
    case lastMonth
    case thisYear

    var displayName: String {
        switch self {
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .thisYear: return "本年"
        }
    }
}

// MARK: - 口径（支出 / 收入）

/// 顶部「支出 / 收入」分段切换的口径。
///
/// 为什么要显式建模：分类占比与累计趋势都要跟着它换一套数据，
/// 而"支出 vs 收入"如果用 `Bool` 表示，`isIncome ? .income : .expense` 会散落在五六个地方，
/// 一旦某处忘了换，页面上就会出现"标题写着收入、数字是支出"的错配。
enum StatisticsMetric: String, CaseIterable, Hashable, Sendable {
    case expense
    case income

    var displayName: String {
        switch self {
        case .expense: return "支出"
        case .income: return "收入"
        }
    }

    /// 对应的账目类型（转账两个口径都不算）。
    var entryType: EntryType {
        switch self {
        case .expense: return .expense
        case .income: return .income
        }
    }
}

// MARK: - 输出类型

/// 一个月的收支。
struct MonthlyFlow: Identifiable, Hashable, Sendable {

    /// `yyyyMM`
    let monthKey: Int32
    let expense: Money
    let income: Money

    var id: Int32 { monthKey }

    /// 「11月」；跨年时补上年份（「25/12」），否则 6 个月的柱子会分不清哪根是哪年。
    var label: String {
        let month = Int(monthKey % 100)
        let year = Int(monthKey / 100) % 100
        return "\(year)/\(month)"
    }

    /// 「11月」这种短标签（同一自然年内用）。
    var shortLabel: String {
        "\(Int(monthKey % 100))月"
    }
}

/// 一个分类的占比。
struct CategoryShare: Identifiable, Hashable, Sendable {

    /// 分类 id；`nil` + `isMerged == true` 表示合并出来的「其他」，
    /// `nil` + `isMerged == false` 表示无分类的记录。
    let categoryID: UUID?
    let amount: Money
    /// 0…1
    let ratio: Double
    let isMerged: Bool

    var id: String {
        if let categoryID { return categoryID.uuidString }
        return isMerged ? "merged.other" : "uncategorized"
    }

    /// 百分比整数（四舍五入到整 %）。
    var percent: Int { Int((ratio * 100).rounded()) }
}

/// 累计趋势上的一个点。
struct DailyTrendPoint: Identifiable, Hashable, Sendable {

    /// 1…31
    let day: Int
    /// 本月累计支出。
    let cumulative: Money
    /// 上月同期累计；上月没有这一天时为 nil（折线只画到上月最后一天）。
    let previousCumulative: Money?

    var id: Int { day }
}

/// 一次统计的完整结果。
struct StatisticsSnapshot: Hashable, Sendable {

    let range: StatisticsRange
    /// 当前口径（决定分类占比与累计趋势看的是支出还是收入）。
    let metric: StatisticsMetric
    /// 当前范围内的支出合计。
    let totalExpense: Money
    /// 当前范围内的收入合计。
    let totalIncome: Money
    /// 近 6 个月收支（含当前范围所在月）。
    let monthlySeries: [MonthlyFlow]
    /// 当前范围的分类占比（已排序、已合并）。
    let categoryShares: [CategoryShare]
    /// 被合并进「其他」的分类 id 集合（下钻时用来精确筛选，而不是"显示全部"）。
    let mergedCategoryIDs: Set<UUID>
    /// 环中心显示的合计（= 当前口径的合计，单独留一个字段让视图语义清楚）。
    let categoryTotal: Money
    /// 本月与上月同期的累计趋势。
    let trend: [DailyTrendPoint]
    /// 当前范围是否有数据（决定空态）。
    let hasExpenseData: Bool
    let hasIncomeData: Bool

    /// 完全空（支出和收入都没有）。
    var isEmpty: Bool { !hasExpenseData && !hasIncomeData }

    /// 当前口径有没有数据（决定分类环与趋势卡的空态）。
    var hasMetricData: Bool { categoryTotal.cents > 0 }

    /// 空快照（加载中/出错时的安全值）。
    static func empty(
        range: StatisticsRange = .thisMonth,
        metric: StatisticsMetric = .expense
    ) -> StatisticsSnapshot {
        StatisticsSnapshot(
            range: range,
            metric: metric,
            totalExpense: .zero,
            totalIncome: .zero,
            monthlySeries: [],
            categoryShares: [],
            mergedCategoryIDs: [],
            categoryTotal: .zero,
            trend: [],
            hasExpenseData: false,
            hasIncomeData: false
        )
    }
}

// MARK: - 计算器

/// 统计聚合（纯函数）。
enum StatisticsCalculator {

    /// 饼图最多几块（超过就合并成「其他」）。
    static let categoryLimit = 8

    /// 近几个月（含当月）。
    static let monthlyWindow = 6

    /// 「无分类」在内部聚合里的占位 id。
    static let uncategorizedKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        ?? UUID()

    // MARK: 范围

    /// 范围 → 日键区间（闭区间）。
    static func dayRange(of range: StatisticsRange, today: DateOnly) -> ClosedRange<Int32> {
        switch range {
        case .thisMonth:
            return DateOnly.monthRange(today.monthKey)
        case .lastMonth:
            return DateOnly.monthRange(previousMonthKey(of: today.monthKey))
        case .thisYear:
            let start = Int32(today.year * 10_000 + 101)
            let end = Int32(today.year * 10_000 + 1231)
            return start...end
        }
    }

    /// 上一个月的月键（`202601` 的上一个月是 `202512`）。
    static func previousMonthKey(of monthKey: Int32) -> Int32 {
        let year = Int(monthKey / 100)
        let month = Int(monthKey % 100)
        if month <= 1 { return Int32((year - 1) * 100 + 12) }
        return Int32(year * 100 + month - 1)
    }

    /// `monthKey` 之后第 `offset` 个月（负数向前）。
    static func shiftMonth(_ monthKey: Int32, by offset: Int) -> Int32 {
        var year = Int(monthKey / 100)
        var month = Int(monthKey % 100) + offset
        while month > 12 { month -= 12; year += 1 }
        while month < 1 { month += 12; year -= 1 }
        return Int32(year * 100 + month)
    }

    // MARK: 聚合

    /// 某个范围内的支出 / 收入合计（转账不计）。
    static func totals(
        _ entries: [LedgerLite],
        range: StatisticsRange,
        today: DateOnly
    ) -> (expense: Money, income: Money) {
        let bounds = dayRange(of: range, today: today)
        var expense: Int64 = 0
        var income: Int64 = 0

        for entry in entries where entry.isCountable {
            guard bounds.contains(entry.occurredDay) else { continue }
            switch entry.type {
            case .expense:
                expense = saturatingAdd(expense, entry.amount)
            case .income:
                income = saturatingAdd(income, entry.amount)
            case .transfer:
                continue
            }
        }
        return (Money(cents: expense), Money(cents: income))
    }

    /// 近 `months` 个月（含 `endingAt`）的收支序列。**空月补 0**，绝不缺项。
    ///
    /// 缺项会让柱状图把 3 个月的数据画成 5 根柱子挤在一起，x 轴看起来"跳月"了。
    static func monthlySeries(
        _ entries: [LedgerLite],
        endingAt monthKey: Int32,
        months: Int = monthlyWindow
    ) -> [MonthlyFlow] {
        let count = max(months, 1)
        var buckets: [Int32: (expense: Int64, income: Int64)] = [:]

        for entry in entries where entry.isCountable {
            guard entry.type == .expense || entry.type == .income else { continue }
            let key = entry.monthKey
            var bucket = buckets[key] ?? (0, 0)
            if entry.type == .expense {
                bucket.expense = saturatingAdd(bucket.expense, entry.amount)
            } else {
                bucket.income = saturatingAdd(bucket.income, entry.amount)
            }
            buckets[key] = bucket
        }

        let firstMonth = shiftMonth(monthKey, by: -(count - 1))
        return (0..<count).map { offset in
            let key = shiftMonth(firstMonth, by: offset)
            let bucket = buckets[key] ?? (0, 0)
            return MonthlyFlow(
                monthKey: key,
                expense: Money(cents: bucket.expense),
                income: Money(cents: bucket.income)
            )
        }
    }

    /// 分类占比（按金额降序；超过 `limit` 时把后面的合并成「其他」）。
    ///
    /// - Parameters:
    ///   - entries: 全部账目。
    ///   - type: 统计哪种类型的分类（支出用 `.expense`）。
    ///   - range/today: 时间范围。
    ///   - limit: 最多几块（含合并出来的「其他」）。
    static func categoryShares(
        _ entries: [LedgerLite],
        type: EntryType,
        range: StatisticsRange,
        today: DateOnly,
        limit: Int = categoryLimit
    ) -> [CategoryShare] {
        breakdown(entries, type: type, range: range, today: today, limit: limit).shares
    }

    /// 分类拆分（同时给出「被合并进其他」的分类 id）。
    static func breakdown(
        _ entries: [LedgerLite],
        type: EntryType,
        range: StatisticsRange,
        today: DateOnly,
        limit: Int = categoryLimit
    ) -> (shares: [CategoryShare], mergedIDs: Set<UUID>) {
        let bounds = dayRange(of: range, today: today)
        // 用哨兵 UUID 表示「无分类」：`[UUID?: Int64]` 这种可选键字典读起来太容易歧义
        var buckets: [UUID: Int64] = [:]

        for entry in entries where entry.isCountable {
            guard entry.type == type, bounds.contains(entry.occurredDay) else { continue }
            let key = entry.categoryID ?? uncategorizedKey
            buckets[key] = saturatingAdd(buckets[key] ?? 0, entry.amount)
        }

        let total = buckets.values.reduce(Int64(0)) { saturatingAdd($0, $1) }
        guard total > 0 else { return ([], []) }

        // 先按金额降序；金额相同按 id 排，保证顺序稳定（每次刷新不能换位置）
        let sorted = buckets
            .map { (id: $0.key, amount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        let cap = max(limit, 1)
        var shares: [CategoryShare] = []
        var mergedIDs = Set<UUID>()

        if sorted.count <= cap {
            shares = sorted.map {
                CategoryShare(
                    categoryID: $0.id == uncategorizedKey ? nil : $0.id,
                    amount: Money(cents: $0.amount),
                    ratio: Double($0.amount) / Double(total),
                    isMerged: false
                )
            }
        } else {
            let keep = cap - 1   // 留一格给「其他」
            let head = sorted.prefix(keep)
            let tail = sorted.dropFirst(keep)
            let mergedCents = tail.reduce(Int64(0)) { saturatingAdd($0, $1.amount) }

            shares = head.map {
                CategoryShare(
                    categoryID: $0.id == uncategorizedKey ? nil : $0.id,
                    amount: Money(cents: $0.amount),
                    ratio: Double($0.amount) / Double(total),
                    isMerged: false
                )
            }
            shares.append(
                CategoryShare(
                    categoryID: nil,
                    amount: Money(cents: mergedCents),
                    ratio: Double(mergedCents) / Double(total),
                    isMerged: true
                )
            )
            // 合并桶下钻时要能精确筛出这些分类的记录（否则只能"显示全部支出"）
            for item in tail where item.id != uncategorizedKey {
                mergedIDs.insert(item.id)
            }
        }

        return (shares, mergedIDs)
    }

    /// 本月累计支出趋势（含上月同期，用于虚线对比）。
    ///
    /// - 点数固定 = **本月天数**（28…31），x 轴不会因为数据少而缩短；
    /// - 上月不足本月天数时（如本月 31 天、上月 30 天），多出来的那天
    ///   `previousCumulative` 为 nil——折线自然停在上月最后一天；
    /// - 本月"未来"的日子累计值沿用前一天（不是 0），否则折线会在今天之后掉到 0，
    ///   看起来像"钱被退回来了"。
    static func trend(
        _ entries: [LedgerLite],
        monthKey: Int32,
        previousMonthKey previous: Int32,
        type: EntryType = .expense
    ) -> [DailyTrendPoint] {
        let year = Int(monthKey / 100)
        let month = Int(monthKey % 100)
        let days = DateOnly.daysInMonth(year: year, month: month)

        let previousYear = Int(previous / 100)
        let previousMonth = Int(previous % 100)
        let previousDays = DateOnly.daysInMonth(year: previousYear, month: previousMonth)

        var thisDaily = [Int](repeating: 0, count: days)
        var prevDaily = [Int](repeating: 0, count: previousDays)

        for entry in entries where entry.isCountable && entry.type == type {
            if entry.monthKey == monthKey {
                let index = entry.occurredDate.day - 1
                if thisDaily.indices.contains(index) {
                    thisDaily[index] = Int(saturatingAdd(Int64(thisDaily[index]), entry.amount))
                }
            } else if entry.monthKey == previous {
                let index = entry.occurredDate.day - 1
                if prevDaily.indices.contains(index) {
                    prevDaily[index] = Int(saturatingAdd(Int64(prevDaily[index]), entry.amount))
                }
            }
        }

        var thisRunning: Int64 = 0
        var prevRunning: Int64 = 0
        var points: [DailyTrendPoint] = []
        points.reserveCapacity(days)

        for day in 1...days {
            thisRunning = saturatingAdd(thisRunning, Int64(thisDaily[day - 1]))

            let previousCumulative: Money?
            if day <= previousDays {
                prevRunning = saturatingAdd(prevRunning, Int64(prevDaily[day - 1]))
                previousCumulative = Money(cents: prevRunning)
            } else {
                previousCumulative = nil
            }

            points.append(
                DailyTrendPoint(
                    day: day,
                    cumulative: Money(cents: thisRunning),
                    previousCumulative: previousCumulative
                )
            )
        }
        return points
    }

    /// 一次性算出整页需要的所有数据。
    static func snapshot(
        _ entries: [LedgerLite],
        range: StatisticsRange,
        today: DateOnly,
        metric: StatisticsMetric = .expense,
        categoryLimit: Int = categoryLimit
    ) -> StatisticsSnapshot {
        let totals = totals(entries, range: range, today: today)
        let series = monthlySeries(entries, endingAt: today.monthKey)
        // 分类占比与趋势都跟着顶部口径走：切到"收入"时看到的就是收入的分类分布
        let breakdown = breakdown(
            entries,
            type: metric.entryType,
            range: range,
            today: today,
            limit: categoryLimit
        )
        // 趋势固定看"本月 vs 上月"，与顶部范围无关：它回答的是"这个月花得快不快 / 进得多不多"
        let trendPoints = trend(
            entries,
            monthKey: today.monthKey,
            previousMonthKey: previousMonthKey(of: today.monthKey),
            type: metric.entryType
        )
        let metricTotal = metric == .expense ? totals.expense : totals.income

        return StatisticsSnapshot(
            range: range,
            metric: metric,
            totalExpense: totals.expense,
            totalIncome: totals.income,
            monthlySeries: series,
            categoryShares: breakdown.shares,
            mergedCategoryIDs: breakdown.mergedIDs,
            categoryTotal: metricTotal,
            trend: trendPoints,
            hasExpenseData: totals.expense.cents > 0,
            hasIncomeData: totals.income.cents > 0
        )
    }

    // MARK: 工具

    /// 饱和加法：宁可封顶也不溢出成负数（统计里出现负数金额是灾难性的）。
    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? Int64.max : Int64.min) : sum
    }
}
