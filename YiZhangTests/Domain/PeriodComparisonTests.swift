//
//  PeriodComparisonTests.swift
//  一账Tests / Domain
//
//  统计页「同比 / 环比」的区间口径 + 文案（V1.1 F-ACC-16，任务书 §2 §5 ②–⑤⑦）。
//
//  为什么口径必须逐条钉死：同比/环比最容易错的地方从来不是除法，而是**拿哪两段去比**。
//  错一天、错一整个月，金额仍然"看起来正常"，只有对着日历逐条核才看得出来。
//  这里用固定 `today` 把四种形状全覆盖：
//  ① 月内到某日（本月档）；
//  ② 整月（上月档，且上上月有 31 天）；
//  ③ 31 日遇到不足 31 天的基线月（夹到月末，不能造出 20260431）；
//  ④ 2 月 29 日遇到平年（夹到 2 月 28 日）。
//
//  另一半是文案：`ComparisonCopy` 的五条分支 + 「新增」与「去年同月无数据」
//  **同时出现**这条容易被写成互斥的规则。
//

import XCTest
@testable import YiZhang

final class PeriodComparisonTests: XCTestCase {

    /// 2025-11-20（11 月 30 天；上月 10 月 31 天；去年同月 2024-11 也是 30 天）。
    private let today = DateOnly(key: 20251120)

    /// 2026-05-31（本月 31 天，上月 4 月只有 30 天）。
    private let mayEndToday = DateOnly(key: 20260531)

    /// 2028-02-29（闰日；去年同月 2027-02 只有 28 天）。
    private let leapDayToday = DateOnly(key: 20280229)

    // MARK: - ② 同比同期对齐

    func testThisMonthYearOverYearComparesSameDaysLastYear() throws {
        let entries = [
            // 当期：11 月 1–20 日之间
            lite(20251105, 1_200),
            // 去年同期：去年 11 月 1–20 日之间
            lite(20241115, 1_000),
            // 去年 11 月 25 日 —— 去年同期的"未来"，绝不能进基线
            lite(20241125, 999),
            // 去年 10 月 —— 不是去年同期
            lite(20241015, 777),
            // 今年 10 月下旬 —— 既不是当期，也不在"上月同期（10 月 1–20 日）"的基线里
            lite(20251025, 555)
        ]

        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(result.yoy.current.cents, 1_200, "当期 = 本月 1 日…今天")
        XCTAssertEqual(result.yoy.baseline.cents, 1_000, "基线 = 去年同月 1–20 日，不能把去年 21 日之后的算进来")
        XCTAssertEqual(result.yoy.direction, .increase)
        XCTAssertEqual(result.yoy.magnitudeThousandths, 200, "1200 比 1000 涨 20.0%")

        // 环比：上月同形状（10 月 1–20 日）
        let mom = try XCTUnwrap(result.mom)
        XCTAssertEqual(mom.current.cents, 1_200)
        XCTAssertEqual(mom.baseline.cents, 0, "上月同期一笔都没有 → 基线为 0")
        XCTAssertEqual(mom.direction, .unavailable)
    }

    func testThisMonthBoundsAreMonthToDateNotWholeMonth() {
        let bounds = StatisticsCalculator.comparisonBounds(range: .thisMonth, today: today)

        XCTAssertEqual(bounds.current, 20251101...20251120, "当期是「本月至今」，不是整月")
        XCTAssertEqual(bounds.yearOverYear, 20241101...20241120, "同比基线必须同样截到 20 日")
        XCTAssertEqual(bounds.monthOverMonth, 20251001...20251020)
    }

    func testThisMonthRecordsAfterTodayDoNotJoinCurrentPeriod() {
        // 任务书口径写的是"本月 1 日…今天"。这里用一条未来的账目把这条边界钉住：
        // 如果实现改成整月（`dayRange`），当期会多出 800
        let entries = [lite(20251105, 1_200), lite(20251128, 800)]

        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(result.yoy.current.cents, 1_200, "今天之后的账目不属于「至今」")
    }

    /// 「本月至今」与「本月整月」在生产环境恒等 —— 把这条**隐性耦合**钉成断言。
    ///
    /// `comparison` 的当期是「1 日…今天」，`snapshot` / `accountShares` 是 `dayRange` 的整月。
    /// 两者能对上，完全依赖 `LedgerService.validateDay` 拒绝未来日期这一**外部约束**
    /// （写入侧永不产生未来账目）。所以这里**刻意只造 ≤ today 的账目**：
    /// 一旦将来放开未来记账，这条测试会红，而不是让用户看到统计页两个数字打架。
    /// 见 `StatisticsCalculator.comparison` 头注释里的「口径依赖」一节。
    func testCurrentPeriodEqualsSnapshotTotalWhenNoFutureEntries() {
        // 全部落在 11 月 1–20 日之间（today = 20251120），也就是"至今"与"整月"重合的那一段
        let entries = [
            lite(20251101, 1_000),
            lite(20251109, 2_500),
            lite(20251120, 400),
            lite(20251120, 700),
            lite(20251115, 9_900, type: .income),
            lite(20251031, 3_000),   // 上月：不影响本月合计
            lite(20241105, 5_000)    // 去年同月：不影响本月合计
        ]

        for range in [StatisticsRange.thisMonth, .lastMonth] {
            let snapshot = StatisticsCalculator.snapshot(
                entries,
                range: range,
                today: today,
                metric: .expense
            )
            let result = StatisticsCalculator.comparison(
                entries,
                range: range,
                metric: .expense,
                today: today
            )

            XCTAssertEqual(
                result.yoy.current,
                snapshot.categoryTotal,
                "\(range.displayName)差额：「至今」必须等于「整月」——靠的是写入侧不产生未来账目"
            )
            XCTAssertEqual(result.yoy.current, snapshot.totalExpense, "口径要与 totals 同源")
        }

        // 本年档同样成立（`snapshot` 的本年区间本来就截至今天，不存在"整月"差异）
        let yearlySnapshot = StatisticsCalculator.snapshot(
            entries,
            range: .thisYear,
            today: today,
            metric: .expense
        )
        let yearlyComparison = StatisticsCalculator.comparison(
            entries,
            range: .thisYear,
            metric: .expense,
            today: today
        )
        XCTAssertEqual(yearlyComparison.yoy.current, yearlySnapshot.categoryTotal)
    }

    // MARK: - ② 上月档：整月 vs 整月

    func testLastMonthComparesWholeMonths() {
        let decemberToday = DateOnly(key: 20251215)
        let entries = [
            lite(20251130, 3_000),   // 上月最后一天：整月口径必须包含
            lite(20251031, 2_000),   // 上上月最后一天：环比基线必须包含
            lite(20241130, 1_000),   // 去年同月最后一天：同比基线必须包含
            lite(20251201, 9_999)    // 本月：不属于上月档
        ]

        let result = StatisticsCalculator.comparison(
            entries,
            range: .lastMonth,
            metric: .expense,
            today: decemberToday
        )

        XCTAssertEqual(result.yoy.current.cents, 3_000)
        XCTAssertEqual(result.yoy.baseline.cents, 1_000)
        XCTAssertEqual(result.mom?.baseline.cents, 2_000, "上上月 = 10 月整月，31 日那天不能漏")

        let bounds = StatisticsCalculator.comparisonBounds(range: .lastMonth, today: decemberToday)
        XCTAssertEqual(bounds.current, 20251101...20251130)
        XCTAssertEqual(bounds.yearOverYear, 20241101...20241130)
        XCTAssertEqual(bounds.monthOverMonth, 20251001...20251031, "10 月 31 天，基线也是整月")
    }

    // MARK: - ③ 31 日遇到不足 31 天的基线月

    func testThirtyFirstDayClampsBaselineToEndOfShorterMonth() {
        // 今天 = 2026-05-31，环比基线 = 4 月（30 天）
        let bounds = StatisticsCalculator.comparisonBounds(range: .thisMonth, today: mayEndToday)

        XCTAssertEqual(bounds.current, 20260501...20260531)
        XCTAssertEqual(bounds.monthOverMonth, 20260401...20260430, "不能造出 20260431 这种不存在的日期")
        XCTAssertEqual(bounds.yearOverYear, 20250501...20250531, "去年 5 月也是 31 天，不夹")
    }

    func testClampedBaselineStillCountsTheLastDayOfTheShorterMonth() {
        let entries = [
            lite(20260510, 1_000),   // 当期
            lite(20260430, 800),     // 4 月最后一天 —— 夹到月末后必须被算进来
            lite(20260305, 444)      // 3 月：既不是当期，也不是 4 月基线
        ]

        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: mayEndToday
        )

        XCTAssertEqual(result.mom?.baseline.cents, 800, "夹到 4 月 30 日之后，4/30 那笔必须在基线里")
        XCTAssertEqual(result.mom?.magnitudeThousandths, 250, "(1000-800)/800 = 25.0%")
    }

    func testLeapDayClampsLastYearToTwentyEightFebruary() {
        let bounds = StatisticsCalculator.comparisonBounds(range: .thisMonth, today: leapDayToday)

        XCTAssertEqual(bounds.current, 20280201...20280229)
        XCTAssertEqual(bounds.yearOverYear, 20270201...20270228, "2027 年 2 月只有 28 天")

        let entries = [
            lite(20280210, 1_000),
            lite(20270228, 500),     // 平年 2 月最后一天，必须计入
            lite(20270301, 9_999)    // 3 月，不属于去年同期
        ]
        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: leapDayToday
        )
        XCTAssertEqual(result.yoy.baseline.cents, 500)
    }

    func testLeapDayInYearRangeClampsToTwentyEightFebruary() {
        // 本年档的同比也是同一个夹紧点：2024-02-29 的"去年今日"是 2023-02-28
        let leapToday = DateOnly(key: 20240229)
        let bounds = StatisticsCalculator.comparisonBounds(range: .thisYear, today: leapToday)

        XCTAssertEqual(bounds.current, 20240101...20240229)
        XCTAssertEqual(bounds.yearOverYear, 20230101...20230228)
        XCTAssertNil(bounds.monthOverMonth)
    }

    // MARK: - ④ 基线为空

    func testEmptyLastYearBaselineIsUnavailableWithExplicitCopy() {
        let entries = [lite(20251105, 1_200), lite(20251110, 300)]
        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )
        let bounds = StatisticsCalculator.comparisonBounds(range: .thisMonth, today: today)

        XCTAssertEqual(result.yoy.direction, .unavailable, "去年同月一笔都没有 → 无法算百分比")
        XCTAssertFalse(result.yoy.isAvailable)
        XCTAssertEqual(result.yoy.current.cents, 1_500, "当期金额照常给出，不能因为没法比就归零")

        // 变化文案说"新增"，小字说"为什么"——两者不是互斥关系
        XCTAssertEqual(ComparisonCopy.changeText(result.yoy), "新增")
        XCTAssertEqual(ComparisonCopy.baselineAmountText(result.yoy), "—", "基线为空时不能显示 ¥0.00")
        XCTAssertEqual(
            ComparisonCopy.detailText(
                slot: .yearOverYear,
                range: .thisMonth,
                comparison: result.yoy,
                bounds: bounds.yearOverYear,
                today: today
            ),
            "去年同月无数据",
            "「新增」旁边必须紧跟「去年同月无数据」，否则用户以为算法坏了"
        )

        // 两个信息同时出现在 VoiceOver 稿里，缺一条就是残缺的朗读
        let spoken = ComparisonCopy.chipAccessibilityText(
            slot: .yearOverYear,
            range: .thisMonth,
            comparison: result.yoy,
            detail: "去年同月无数据"
        )
        XCTAssertTrue(spoken.contains("新增"), "朗读稿缺方向：\(spoken)")
        XCTAssertTrue(spoken.contains("去年同月无数据"), "朗读稿缺原因：\(spoken)")
        XCTAssertTrue(spoken.contains("没有数据"), "基线金额要读成「没有数据」，不是「零元」：\(spoken)")
    }

    func testBothPeriodsEmptyReadsAsDashNotNew() {
        // 当期与基线都空：不能显示「新增」（那是"这个月新花了钱"的意思）
        let result = StatisticsCalculator.comparison(
            [],
            range: .thisMonth,
            metric: .expense,
            today: today
        )
        XCTAssertEqual(result.yoy.direction, .flat)
        XCTAssertEqual(ComparisonCopy.changeText(result.yoy), "—")
    }

    func testZeroCurrentWithNonZeroBaselineStillShowsPercentage() {
        // 当期 0、基线有数 → 「▼100%」是一个有信息量的结论，不能藏进空态，也不能显示成「新增」
        let entries = [lite(20241115, 1_000)]
        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(result.yoy.current.cents, 0)
        XCTAssertEqual(result.yoy.direction, .decrease)
        XCTAssertEqual(result.yoy.magnitudeThousandths, 1_000)
        XCTAssertEqual(ComparisonCopy.changeText(result.yoy), "▼100.0%")
    }

    // MARK: - ⑤ 本年档没有环比

    func testYearRangeHasNoMonthOverMonth() {
        let result = StatisticsCalculator.comparison(
            [lite(20250301, 1_000), lite(20240301, 800)],
            range: .thisYear,
            metric: .expense,
            today: DateOnly(key: 20251120)
        )

        XCTAssertNil(result.mom, "年粒度谈「较上期」没有直觉含义，`.mom == nil` 而不是 `.flat` 占位")
        XCTAssertEqual(result.yoy.current.cents, 1_000)
        XCTAssertEqual(result.yoy.baseline.cents, 800)

        let bounds = StatisticsCalculator.comparisonBounds(range: .thisYear, today: today)
        XCTAssertEqual(bounds.current, 20250101...20251120)
        XCTAssertEqual(bounds.yearOverYear, 20240101...20241120)
        XCTAssertNil(bounds.monthOverMonth)
    }

    func testMonthRangesDoHaveMonthOverMonth() {
        XCTAssertNotNil(StatisticsCalculator.comparisonBounds(range: .thisMonth, today: today).monthOverMonth)
        XCTAssertNotNil(StatisticsCalculator.comparisonBounds(range: .lastMonth, today: today).monthOverMonth)
    }

    // MARK: - 三条不变量（转账 / 软删 / 口径）

    func testTransfersNeverJoinEitherPeriod() {
        let entries = [
            lite(20251105, 1_000),
            lite(20251106, 50_000, type: .transfer),
            lite(20241115, 900),
            lite(20241116, 50_000, type: .transfer)
        ]

        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(result.yoy.current.cents, 1_000, "转账不是支出")
        XCTAssertEqual(result.yoy.baseline.cents, 900, "转账也不是基线里的支出")
    }

    func testIncomeMetricUsesIncomeOnly() {
        let entries = [
            lite(20251105, 8_000, type: .income),
            lite(20251106, 1_000, type: .expense),
            lite(20241115, 6_000, type: .income)
        ]

        let result = StatisticsCalculator.comparison(
            entries,
            range: .thisMonth,
            metric: .income,
            today: today
        )

        XCTAssertEqual(result.yoy.current.cents, 8_000)
        XCTAssertEqual(result.yoy.baseline.cents, 6_000)
    }

    // MARK: - ⑦ 软删（计算器层：两处口径同步减少）

    func testSoftDeletedEntryLeavesBothCards() {
        let accountA = account(1)
        let entries = [
            lite(20251105, 1_000, account: accountA),
            lite(20251106, 400, account: accountA)
        ]

        let before = StatisticsCalculator.comparison(entries, range: .thisMonth, metric: .expense, today: today)
        let beforeShares = StatisticsCalculator.accountShares(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )
        XCTAssertEqual(before.yoy.current.cents, 1_400)
        XCTAssertEqual(beforeShares.shares.reduce(Int64(0)) { $0 + $1.amount.cents }, 1_400)

        // 软删第二笔：两处必须同步减少，不能一处减一处不减
        let after = [
            lite(20251105, 1_000, account: accountA),
            lite(20251106, 400, account: accountA, deleted: true)
        ]
        let afterResult = StatisticsCalculator.comparison(after, range: .thisMonth, metric: .expense, today: today)
        let afterShares = StatisticsCalculator.accountShares(
            after,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(afterResult.yoy.current.cents, 1_000, "对比卡主数字要减掉软删的那笔")
        XCTAssertEqual(
            afterShares.shares.reduce(Int64(0)) { $0 + $1.amount.cents },
            1_000,
            "账户构成也要减掉同一笔"
        )
    }

    // MARK: - 文案：五条分支

    func testChangeTextCoversAllFiveBranches() {
        let increase = makeComparison(current: 112, baseline: 100)
        XCTAssertEqual(ComparisonCopy.changeText(increase), "▲12.0%")

        let decrease = makeComparison(current: 92, baseline: 100)
        XCTAssertEqual(ComparisonCopy.changeText(decrease), "▼8.0%")

        let flatWithMoney = makeComparison(current: 2_500, baseline: 2_500)
        XCTAssertEqual(ComparisonCopy.changeText(flatWithMoney), "持平", "两期金额完全相等才叫持平")

        let flatEmpty = makeComparison(current: 0, baseline: 0)
        XCTAssertEqual(ComparisonCopy.changeText(flatEmpty), "—", "两期都空说「持平」等于造假")

        let newly = makeComparison(current: 1_200, baseline: 0)
        XCTAssertEqual(ComparisonCopy.changeText(newly), "新增")

        // `.unavailable` + 当期 0 只有手构造才可能出现（`make` 会判成 `.flat`），
        // 但值类型允许，文案就必须全定义 —— 否则将来新增一条构造路径会崩在视图里
        let unavailableEmpty = PeriodComparison(
            current: .zero,
            baseline: .zero,
            direction: .unavailable,
            magnitudeThousandths: 0
        )
        XCTAssertEqual(ComparisonCopy.changeText(unavailableEmpty), "—")
    }

    func testChangeTextUsesTheCappedPercentText() {
        // 基线一元、当期一千元：真实涨幅 99,900%，必须走"999%+"而不是印五位数
        let explode = makeComparison(current: 100_000, baseline: 1)
        XCTAssertEqual(ComparisonCopy.changeText(explode), "▲999%+")
    }

    func testSlotAndCaptionVocabulary() {
        XCTAssertEqual(ComparisonCopy.slotLabel(.yearOverYear), "同比")
        XCTAssertEqual(ComparisonCopy.slotLabel(.monthOverMonth), "环比")

        XCTAssertEqual(ComparisonCopy.currentCaption(.thisMonth), "本月至今")
        XCTAssertEqual(ComparisonCopy.currentCaption(.lastMonth), "上月整月")
        XCTAssertEqual(ComparisonCopy.currentCaption(.thisYear), "本年至今")

        XCTAssertEqual(ComparisonCopy.baselineCaption(slot: .yearOverYear, range: .thisMonth), "去年同月")
        XCTAssertEqual(ComparisonCopy.baselineCaption(slot: .yearOverYear, range: .thisYear), "去年同期")
        XCTAssertEqual(ComparisonCopy.baselineCaption(slot: .monthOverMonth, range: .thisMonth), "上月同期")
        XCTAssertEqual(
            ComparisonCopy.baselineCaption(slot: .monthOverMonth, range: .lastMonth),
            "上上月",
            "上月档的上一段是整月，说「上月同期」会指错区间"
        )
    }

    func testEmptyBaselineVocabularyFollowsRange() {
        XCTAssertEqual(ComparisonCopy.emptyBaselineText(slot: .yearOverYear, range: .thisMonth), "去年同月无数据")
        XCTAssertEqual(ComparisonCopy.emptyBaselineText(slot: .yearOverYear, range: .lastMonth), "去年同月无数据")
        XCTAssertEqual(ComparisonCopy.emptyBaselineText(slot: .yearOverYear, range: .thisYear), "去年同期无数据")
        XCTAssertEqual(ComparisonCopy.emptyBaselineText(slot: .monthOverMonth, range: .thisMonth), "上月无数据")
        XCTAssertEqual(ComparisonCopy.emptyBaselineText(slot: .monthOverMonth, range: .lastMonth), "上上月无数据")
    }

    // MARK: - 文案：区间小字

    func testRangeTextForWholeMonthOmitsDays() {
        XCTAssertEqual(
            ComparisonCopy.rangeText(20241101...20241130, today: today),
            "去年 11 月",
            "整月不必写「1 日–30 日」，那是噪音"
        )
    }

    func testRangeTextForMonthToDateUsesEnDash() {
        // 注意这里是 U+2013 EN DASH（–），不是 ASCII 连字符（-）
        let text = ComparisonCopy.rangeText(20241101...20241120, today: today)
        XCTAssertEqual(text, "去年 11 月 1–20 日")
        XCTAssertTrue(text.contains("\u{2013}"), "区间连接符必须是 EN DASH，用 ASCII 连字符在中文排版里会被读成减号")
    }

    func testRangeTextForSingleDayAndCurrentYear() {
        XCTAssertEqual(ComparisonCopy.rangeText(20241105...20241105, today: today), "去年 11 月 5 日")
        XCTAssertEqual(ComparisonCopy.rangeText(20251101...20251120, today: today), "11 月 1–20 日")
    }

    func testRangeTextAcrossMonthsForYearRange() {
        XCTAssertEqual(
            ComparisonCopy.rangeText(20240101...20240305, today: DateOnly(key: 20250305)),
            "去年 1 月 1 日–3 月 5 日"
        )
    }

    func testRangeTextFallsBackToAbsoluteYearForOlderPeriods() {
        // 两年前不能写"去年"，会指错年份
        XCTAssertEqual(ComparisonCopy.rangeText(20231101...20231130, today: today), "2023 年 11 月")
    }

    func testRangeTextReturnsEmptyForInvalidBounds() {
        XCTAssertEqual(ComparisonCopy.rangeText(0...0, today: today), "")
    }

    func testDetailTextShowsActualRangeWhenBaselineExists() {
        let comparison = makeComparison(current: 1_200, baseline: 1_000)
        let bounds = StatisticsCalculator.comparisonBounds(range: .thisMonth, today: today)

        XCTAssertEqual(
            ComparisonCopy.detailText(
                slot: .yearOverYear,
                range: .thisMonth,
                comparison: comparison,
                bounds: bounds.yearOverYear,
                today: today
            ),
            "去年 11 月 1–20 日",
            "同比卡片必须写清「和哪 20 天比」，否则用户会拿去年整月的心智去读它"
        )
    }

    // MARK: - 夹具

    /// 账户 id 前缀用 `000a`，避开 `unassignedAccountKey`（`...-0000-000000000001`）：
    /// 撞上哨兵的话，这个账户的账目会被并进「未知账户」，测试看起来"莫名其妙多一行"。
    private func account(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-000a-%012d", index)) ?? UUID()
    }

    private func lite(
        _ day: Int32,
        _ amount: Int64,
        type: EntryType = .expense,
        account: UUID? = nil,
        deleted: Bool = false
    ) -> LedgerLite {
        LedgerLite(
            id: UUID(),
            amount: amount,
            typeRaw: type.raw,
            occurredDay: day,
            accountID: account,
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        )
    }

    private func makeComparison(current: Int64, baseline: Int64) -> PeriodComparison {
        PeriodComparison.make(current: Money(cents: current), baseline: Money(cents: baseline))
    }
}
