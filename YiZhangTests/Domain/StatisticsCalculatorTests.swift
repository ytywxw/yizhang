//
//  StatisticsCalculatorTests.swift
//  一账Tests / Domain
//
//  T19 的聚合全部在 `StatisticsCalculator` 里，是纯函数——所以"占比加起来是不是 100%"
//  "空月有没有补 0""上月只有 30 天时折线画到哪停"这类**只在特定日期形状下才暴露**的错误，
//  可以在这里用固定日期逐条钉死，不需要跑模拟器。
//
//  刻意覆盖的 13 个场景：
//  ① 支出 / 收入分开合计，转账两边都不计；
//  ② 软删记录不计入（删了还占占比是最容易犯的错）；
//  ③ 近 6 个月序列**空月补 0**（缺项会让 x 轴跳月）；
//  ④ 跨年：1 月的 6 个月窗口要落到上一年 8 月；
//  ⑤ 分类占比之和 = 100%（±1，允许四舍五入）；
//  ⑥ 分类按金额降序、顺序稳定（同金额时按 id，刷新不能换位置）；
//  ⑦ 超过 8 类合并成「其他」，且 `mergedCategoryIDs` 能精确还原被合并的类；
//  ⑧ 无分类的记录聚成一个 `categoryID == nil` 的桶；
//  ⑨ 趋势点数 = 本月天数（28…31），不因数据少而缩短；
//  ⑩ 趋势是**累计**，不是当日；
//  ⑪ 上月天数少时，多出来的那天 `previousCumulative == nil`（虚线自然停住）；
//  ⑫ 未来日期沿用前一天累计值（不能掉到 0，否则像"钱被退回来了"）；
//  ⑬ 空月份不产出分类块（避免画一个 100% 的空环）。
//

import XCTest
@testable import YiZhang

final class StatisticsCalculatorTests: XCTestCase {

    /// 固定"今天"：2026-11-21（11 月 30 天，上月 10 月 31 天）。
    private let today = DateOnly(key: 20261121)

    /// 固定"今天"（31 天的月份）：2026-12-15（12 月 31 天，上月 11 月 30 天）。
    private let decemberToday = DateOnly(key: 20261215)

    // MARK: - ① 收支合计

    func testThisMonthTotalsSeparateExpenseAndIncome() {
        let entries = [
            lite(20261102, 1200),
            lite(20261110, 800),
            lite(20261115, 1_200_000, type: .income),
            // 上月的数据不能混进本月
            lite(20261031, 999),
            lite(20261201, 777)
        ]

        let totals = StatisticsCalculator.totals(entries, range: .thisMonth, today: today)

        XCTAssertEqual(totals.expense.cents, 2000)
        XCTAssertEqual(totals.income.cents, 1_200_000)
    }

    func testTransfersAreExcludedFromBothSides() {
        let entries = [
            lite(20261103, 500),
            lite(20261104, 50_000, type: .transfer)
        ]

        let totals = StatisticsCalculator.totals(entries, range: .thisMonth, today: today)

        XCTAssertEqual(totals.expense.cents, 500, "转账不能算支出")
        XCTAssertEqual(totals.income.cents, 0, "转账也不能算收入")
    }

    func testSoftDeletedEntriesAreExcluded() {
        let entries = [
            lite(20261105, 3000),
            lite(20261106, 4000, deleted: true)
        ]

        let totals = StatisticsCalculator.totals(entries, range: .thisMonth, today: today)

        XCTAssertEqual(totals.expense.cents, 3000, "软删的 4000 必须被排除")
    }

    func testLastMonthRangeOnlyCountsPreviousMonth() {
        let entries = [
            lite(20261015, 1100),
            lite(20261101, 2200)
        ]

        let totals = StatisticsCalculator.totals(entries, range: .lastMonth, today: today)

        XCTAssertEqual(totals.expense.cents, 1100)
        XCTAssertEqual(StatisticsCalculator.dayRange(of: .lastMonth, today: today), 20261001...20261031)
    }

    func testThisYearRangeCoversWholeCalendarYear() {
        let entries = [
            lite(20260101, 100),
            lite(20261231, 200),
            lite(20251231, 900),   // 去年最后一天
            lite(20270101, 700)    // 明年第一天
        ]

        let totals = StatisticsCalculator.totals(entries, range: .thisYear, today: today)

        XCTAssertEqual(totals.expense.cents, 300)
    }

    // MARK: - ② 近 6 个月序列

    func testMonthlySeriesHasSixMonthsEndingAtCurrentMonth() {
        let series = StatisticsCalculator.monthlySeries([], endingAt: today.monthKey)

        XCTAssertEqual(series.count, 6)
        XCTAssertEqual(series.map(\.monthKey), [202606, 202607, 202608, 202609, 202610, 202611])
        XCTAssertEqual(series.last?.monthKey, today.monthKey)
    }

    func testMonthlySeriesFillsEmptyMonthsWithZero() {
        let entries = [lite(20261102, 1200)]

        let series = StatisticsCalculator.monthlySeries(entries, endingAt: today.monthKey)

        XCTAssertEqual(series.count, 6)
        for flow in series.dropLast() {
            XCTAssertEqual(flow.expense.cents, 0, "\(flow.monthKey) 是空月，必须补 0 而不是缺项")
            XCTAssertEqual(flow.income.cents, 0)
        }
        XCTAssertEqual(series.last?.expense.cents, 1200)
    }

    func testMonthlySeriesCrossesYearBoundary() {
        // 1 月的 6 个月窗口 = 去年 8 月 … 今年 1 月
        let series = StatisticsCalculator.monthlySeries([], endingAt: 202601)

        XCTAssertEqual(series.map(\.monthKey), [202508, 202509, 202510, 202511, 202512, 202601])
        XCTAssertEqual(series[4].label, "25/12", "跨年那根柱子要补年份，否则分不清是哪年 12 月")
        XCTAssertEqual(series[5].shortLabel, "1月")
    }

    func testMonthlySeriesIgnoresTransfersAndDeletedEntries() {
        let entries = [
            lite(20261102, 1000),
            lite(20261103, 5000, type: .transfer),
            lite(20261104, 7000, deleted: true)
        ]

        let series = StatisticsCalculator.monthlySeries(entries, endingAt: today.monthKey)
        let november = series[5]

        XCTAssertEqual(november.expense.cents, 1000)
    }

    func testMonthlySeriesSumsIncomeAndExpenseIntoDifferentColumns() {
        let entries = [
            lite(20261101, 4500),
            lite(20261101, 1_200_000, type: .income)
        ]

        let november = StatisticsCalculator.monthlySeries(entries, endingAt: today.monthKey)[5]

        XCTAssertEqual(november.expense.cents, 4500)
        XCTAssertEqual(november.income.cents, 1_200_000)
    }

    // MARK: - ③ 分类占比
}

// MARK: - 分类占比与趋势（拆成 extension 只是为了文件可读，仍是同一个测试类）

extension StatisticsCalculatorTests {

    func testCategorySharesSumToOneHundred() {
        let entries = [
            lite(20261102, 3000, category: cat(1)),
            lite(20261103, 1500, category: cat(2)),
            lite(20261104, 700, category: cat(3)),
            lite(20261105, 333, category: cat(4))
        ]

        let shares = StatisticsCalculator.categoryShares(
            entries,
            type: .expense,
            range: .thisMonth,
            today: today
        )

        let total = shares.reduce(0) { $0 + $1.percent }
        XCTAssertEqual(total, 100, accuracy: 1, "占比之和必须是 100%（±1 四舍五入）")
        let ratioSum = shares.reduce(0.0) { $0 + $1.ratio }
        XCTAssertEqual(ratioSum, 1.0, accuracy: 0.0001)
    }

    func testCategorySharesAreSortedByAmountDescending() {
        let entries = [
            lite(20261102, 100, category: cat(1)),
            lite(20261103, 900, category: cat(2)),
            lite(20261104, 500, category: cat(3))
        ]

        let shares = StatisticsCalculator.categoryShares(
            entries,
            type: .expense,
            range: .thisMonth,
            today: today
        )

        XCTAssertEqual(shares.map(\.amount.cents), [900, 500, 100])
        XCTAssertEqual(shares.first?.categoryID, cat(2))
    }

    func testCategorySharesMergeBeyondLimitIntoOther() {
        // 10 个分类、上限 8 → 保留金额最大的 7 个 + 1 个「其他」
        let entries = (1...10).map { index in
            lite(20261102, Int64(index) * 100, category: cat(index))
        }

        let breakdown = StatisticsCalculator.breakdown(
            entries,
            type: .expense,
            range: .thisMonth,
            today: today
        )

        XCTAssertEqual(breakdown.shares.count, 8)
        XCTAssertEqual(breakdown.shares.filter(\.isMerged).count, 1)
        let other = breakdown.shares.last
        XCTAssertEqual(other?.isMerged, true)
        XCTAssertEqual(other?.categoryID, nil)
        XCTAssertEqual(other?.amount.cents, 300 + 200 + 100, "3 + 2 + 1 三块被合并")

        // 被合并的 3 个分类必须能被精确还原（下钻时不能"显示全部"）
        XCTAssertEqual(breakdown.mergedIDs, Set([cat(1), cat(2), cat(3)]))
        XCTAssertEqual(breakdown.shares.first?.amount.cents, 1000, "最大的一块不能被合并掉")
    }

    func testUncategorizedEntriesCollapseIntoNilBucket() {
        let entries = [
            lite(20261102, 600),
            lite(20261103, 400),
            lite(20261104, 1000, category: cat(1))
        ]

        let shares = StatisticsCalculator.categoryShares(
            entries,
            type: .expense,
            range: .thisMonth,
            today: today
        )

        XCTAssertEqual(shares.count, 2)
        let uncategorized = shares.first { $0.categoryID == nil && !$0.isMerged }
        XCTAssertNotNil(uncategorized, "两条无分类记录应聚成一桶")
        XCTAssertEqual(uncategorized?.amount.cents, 1000)
    }

    func testCategorySharesCanAggregateIncomeType() {
        let entries = [
            lite(20261102, 1_200_000, type: .income, category: cat(1)),
            lite(20261103, 500, type: .income, category: cat(2)),
            lite(20261104, 3000, type: .expense, category: cat(2))
        ]

        let shares = StatisticsCalculator.categoryShares(
            entries,
            type: .income,
            range: .thisMonth,
            today: today
        )

        XCTAssertEqual(shares.map(\.amount.cents), [1_200_000, 500], "只统计收入，支出不能混进来")
    }

    func testEmptyMonthProducesNoCategoryShares() {
        let entries = [lite(20261015, 3000, category: cat(1))]

        let shares = StatisticsCalculator.categoryShares(
            entries,
            type: .expense,
            range: .thisMonth,
            today: today
        )

        XCTAssertTrue(shares.isEmpty, "本月没有支出 → 不画环，交给空态文案")
    }

    // MARK: - ④ 累计趋势

    func testTrendHasOnePointPerDayOfMonth() {
        let points = StatisticsCalculator.trend(
            [],
            monthKey: decemberToday.monthKey,
            previousMonthKey: 202611
        )

        XCTAssertEqual(points.count, 31, "12 月有 31 天，点数不能因为没数据而减少")
        XCTAssertEqual(points.first?.day, 1)
        XCTAssertEqual(points.last?.day, 31)
    }

    func testTrendIsCumulativeNotDaily() {
        let entries = [
            lite(20261202, 1000),
            lite(20261205, 500)
        ]

        let points = StatisticsCalculator.trend(
            entries,
            monthKey: decemberToday.monthKey,
            previousMonthKey: 202611
        )

        XCTAssertEqual(points[0].cumulative.cents, 0)
        XCTAssertEqual(points[1].cumulative.cents, 1000, "2 日累计 1000")
        XCTAssertEqual(points[2].cumulative.cents, 1000, "3 日没有支出，累计不变")
        XCTAssertEqual(points[4].cumulative.cents, 1500, "5 日累计 1500")
    }

    func testTrendStopsPreviousMonthWhenItIsShorter() {
        // 12 月 31 天、11 月 30 天 → 第 31 天没有"上月同期"
        let entries = [lite(20261120, 800)]

        let points = StatisticsCalculator.trend(
            entries,
            monthKey: decemberToday.monthKey,
            previousMonthKey: 202611
        )

        XCTAssertEqual(points[29].previousCumulative?.cents, 800, "30 日仍在上月范围内")
        XCTAssertNil(points[30].previousCumulative, "31 日超出上月天数，虚线必须停住")
    }

    func testTrendPreviousMonthAccumulatesIndependently() {
        let entries = [
            lite(20261110, 2000),
            lite(20261120, 3000),
            lite(20261203, 700)
        ]

        let points = StatisticsCalculator.trend(
            entries,
            monthKey: decemberToday.monthKey,
            previousMonthKey: 202611
        )

        XCTAssertEqual(points[2].cumulative.cents, 700)
        XCTAssertEqual(points[2].previousCumulative?.cents, 0, "上月 3 日还没花钱")
        XCTAssertEqual(points[9].previousCumulative?.cents, 2000)
        XCTAssertEqual(points[19].previousCumulative?.cents, 5000)
    }

    func testTrendCarriesForwardAfterLastEntry() {
        let entries = [lite(20261102, 1000)]

        let points = StatisticsCalculator.trend(
            entries,
            monthKey: 202611,
            previousMonthKey: 202610
        )

        XCTAssertEqual(points.count, 30, "11 月 30 天")
        XCTAssertEqual(points.last?.cumulative.cents, 1000, "最后一天沿用累计值，不能掉回 0")
    }

    func testTrendIgnoresIncomeAndDeletedEntries() {
        let entries = [
            lite(20261102, 1000),
            lite(20261103, 1_200_000, type: .income),
            lite(20261104, 4000, deleted: true)
        ]

        let points = StatisticsCalculator.trend(
            entries,
            monthKey: 202611,
            previousMonthKey: 202610
        )

        XCTAssertEqual(points.last?.cumulative.cents, 1000, "趋势只看支出")
    }

    // MARK: - ⑤ 快照

    func testSnapshotCombinesEverythingAndRespectsRange() {
        let entries = [
            lite(20261102, 3000, category: cat(1)),
            lite(20261103, 1000, type: .income),
            lite(20261005, 500, category: cat(2))
        ]

        let snapshot = StatisticsCalculator.snapshot(entries, range: .lastMonth, today: today)

        XCTAssertEqual(snapshot.range, .lastMonth)
        XCTAssertEqual(snapshot.totalExpense.cents, 500, "合计跟随顶部范围")
        XCTAssertEqual(snapshot.categoryTotal.cents, 500)
        XCTAssertEqual(snapshot.categoryShares.first?.amount.cents, 500)
        XCTAssertEqual(snapshot.monthlySeries.count, 6, "6 个月柱状图与范围无关")
        XCTAssertEqual(snapshot.trend.count, 30, "趋势固定看本月 vs 上月，与范围无关")
        XCTAssertTrue(snapshot.hasExpenseData)
        XCTAssertFalse(snapshot.hasIncomeData, "上个月没有收入")
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testSnapshotReportsEmptyWhenRangeHasNoData() {
        let entries = [lite(20261102, 3000, category: cat(1))]

        let snapshot = StatisticsCalculator.snapshot(entries, range: .lastMonth, today: today)

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(snapshot.categoryShares.isEmpty)
        XCTAssertEqual(snapshot.totalExpense.cents, 0)
        XCTAssertEqual(StatisticsSnapshot.empty().isEmpty, true)
    }

    // MARK: - ⑤ 支出 / 收入口径切换

    func testSnapshotWithIncomeMetricAggregatesIncomeCategories() {
        let entries = [
            lite(20261102, 3000, category: cat(1)),
            lite(20261103, 1_200_000, type: .income, category: cat(2)),
            lite(20261104, 500, type: .income, category: cat(3))
        ]

        let snapshot = StatisticsCalculator.snapshot(
            entries,
            range: .thisMonth,
            today: today,
            metric: .income
        )

        XCTAssertEqual(snapshot.metric, .income)
        XCTAssertEqual(snapshot.categoryTotal.cents, 1_200_500, "环中心必须是收入合计")
        XCTAssertEqual(snapshot.categoryShares.map(\.amount.cents), [1_200_000, 500])
        XCTAssertEqual(snapshot.categoryShares.first?.categoryID, cat(2))
        XCTAssertEqual(snapshot.totalExpense.cents, 3000, "顶部两张卡仍然各自独立")
        XCTAssertTrue(snapshot.hasMetricData)
    }

    func testSnapshotWithExpenseMetricIgnoresIncomeCategories() {
        let entries = [
            lite(20261102, 3000, category: cat(1)),
            lite(20261103, 1_200_000, type: .income, category: cat(2))
        ]

        let snapshot = StatisticsCalculator.snapshot(
            entries,
            range: .thisMonth,
            today: today,
            metric: .expense
        )

        XCTAssertEqual(snapshot.categoryTotal.cents, 3000)
        XCTAssertEqual(snapshot.categoryShares.map(\.amount.cents), [3000])
    }

    func testTrendSwitchesToIncomeWhenMetricIsIncome() {
        let entries = [
            lite(20261102, 1000),
            lite(20261105, 500_000, type: .income)
        ]

        let snapshot = StatisticsCalculator.snapshot(
            entries,
            range: .thisMonth,
            today: today,
            metric: .income
        )

        XCTAssertEqual(snapshot.trend.last?.cumulative.cents, 500_000, "收入口径下趋势换成收入")
        XCTAssertTrue(snapshot.hasMetricData)
    }

    func testSnapshotIsEmptyForMetricWithoutRecords() {
        let entries = [lite(20261102, 3000, category: cat(1))]

        let snapshot = StatisticsCalculator.snapshot(
            entries,
            range: .thisMonth,
            today: today,
            metric: .income
        )

        XCTAssertFalse(snapshot.hasMetricData, "有支出但没有收入 → 收入口径为空态")
        XCTAssertTrue(snapshot.hasExpenseData)
    }

    func testMetricDisplayNames() {
        XCTAssertEqual(StatisticsMetric.allCases.map(\.displayName), ["支出", "收入"])
        XCTAssertEqual(StatisticsMetric.income.entryType, .income)
        XCTAssertEqual(StatisticsMetric.expense.entryType, .expense)
    }

    // MARK: - ⑥ 工具

    func testShiftMonthWalksAcrossYearsInBothDirections() {
        XCTAssertEqual(StatisticsCalculator.shiftMonth(202601, by: -1), 202512)
        XCTAssertEqual(StatisticsCalculator.shiftMonth(202512, by: 1), 202601)
        XCTAssertEqual(StatisticsCalculator.shiftMonth(202603, by: -5), 202510)
        XCTAssertEqual(StatisticsCalculator.previousMonthKey(of: 202601), 202512)
    }

    func testSaturatingAddDoesNotWrapAround() {
        XCTAssertEqual(StatisticsCalculator.saturatingAdd(1, 2), 3)
        XCTAssertEqual(StatisticsCalculator.saturatingAdd(Int64.max, 1), Int64.max)
        XCTAssertEqual(StatisticsCalculator.saturatingAdd(Int64.min, -1), Int64.min)
    }

    func testRangeDisplayNames() {
        XCTAssertEqual(StatisticsRange.allCases.map(\.displayName), ["本月", "上月", "本年"])
    }

    // MARK: - 夹具

    /// 固定 UUID 的分类 id（同 `index` 恒等，便于断言）。
    private func cat(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)) ?? UUID()
    }

    private func lite(
        _ day: Int32,
        _ amount: Int64,
        type: EntryType = .expense,
        category: UUID? = nil,
        deleted: Bool = false
    ) -> LedgerLite {
        LedgerLite(
            id: UUID(),
            amount: amount,
            typeRaw: type.raw,
            occurredDay: day,
            categoryID: category,
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        )
    }
}
