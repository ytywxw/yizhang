//
//  SubscriptionOverviewTests.swift
//  一账Tests / Domain
//
//  订阅总览是纯整数换算，所以每条折算口径都能被逐分钉死：
//  年付 ÷12、季付 ÷3、周付 ×4.345、每 N 天 ×(30.4 ÷ N)（PRD 4.4）。
//
//  重点验证两件事：
//  ① **先求和再取整**：12 条 ¥0.4 的订阅应该算出 ¥5，而不是 12×¥0=¥0；
//  ② 年度总成本按"一年扣几次"算，不用"每月均值 ×12"（周付一年是 52 次而非 52.14 次）。
//

import XCTest
@testable import YiZhang

final class SubscriptionOverviewTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    // MARK: - 每月固定支出

    func testMonthlyFixedCostUsesPRDConversionTable() {
        let monthly = makeSnapshot(amount: 2500, unit: .month, value: 1)
        let quarterly = makeSnapshot(amount: 7500, unit: .quarter, value: 1)
        let yearly = makeSnapshot(amount: 30000, unit: .year, value: 1)

        XCTAssertEqual(SubscriptionOverview.monthlyThousandths(of: monthly), 2_500_000)
        XCTAssertEqual(SubscriptionOverview.monthlyThousandths(of: quarterly), 2_500_000)
        XCTAssertEqual(SubscriptionOverview.monthlyThousandths(of: yearly), 2_500_000)

        let total = SubscriptionOverview.monthlyFixedCost([monthly, quarterly, yearly])
        XCTAssertEqual(total, Money(cents: 7500), "三条 ¥25/月 折算后应为 ¥75")
    }

    func testWeeklyConversionIsRoundedToYuan() {
        // ¥10 / 周 × 4.345 = ¥43.45 → 约 ¥43
        let weekly = makeSnapshot(amount: 1000, unit: .week, value: 1)
        XCTAssertEqual(SubscriptionOverview.monthlyFixedCost([weekly]), Money(cents: 4300))
    }

    func testDailyConversionWithValueUses304DaysPerMonth() {
        // ¥10 / 45 天 × (30.4 ÷ 45) = ¥6.76 → 约 ¥7
        let everyFortyFiveDays = makeSnapshot(amount: 1000, unit: .day, value: 45)
        XCTAssertEqual(SubscriptionOverview.monthlyFixedCost([everyFortyFiveDays]), Money(cents: 700))
    }

    func testManySmallSubscriptionsAreSummedBeforeRounding() {
        // 12 × ¥0.4 = ¥4.8 → 约 ¥5。若每条先取整到元（¥0）再加，结果会是 ¥0
        let small = (0..<12).map { _ in makeSnapshot(amount: 40, unit: .month, value: 1) }
        XCTAssertEqual(SubscriptionOverview.monthlyFixedCost(small), Money(cents: 500))
    }

    func testNonActiveSubscriptionsAreExcludedFromMonthlyCost() {
        let active = makeSnapshot(amount: 2500, unit: .month, status: .active)
        let paused = makeSnapshot(amount: 9900, unit: .month, status: .paused)
        let cancelled = makeSnapshot(amount: 9900, unit: .month, status: .cancelled)

        let total = SubscriptionOverview.monthlyFixedCost([active, paused, cancelled])
        XCTAssertEqual(total, Money(cents: 2500))
    }

    func testZeroAmountSnapshotsDoNotChangeTotal() {
        let free = makeSnapshot(amount: 0, unit: .month)
        let paid = makeSnapshot(amount: 2500, unit: .month)
        XCTAssertEqual(SubscriptionOverview.monthlyFixedCost([free, paid]), Money(cents: 2500))
    }

    // MARK: - 年度总成本

    func testYearlyCostCountsChargesPerYear() {
        XCTAssertEqual(
            SubscriptionOverview.yearlyCost([makeSnapshot(amount: 2500, unit: .month)]),
            Money(cents: 30000)
        )
        XCTAssertEqual(
            SubscriptionOverview.yearlyCost([makeSnapshot(amount: 12000, unit: .year)]),
            Money(cents: 12000)
        )
        XCTAssertEqual(
            SubscriptionOverview.yearlyCost([makeSnapshot(amount: 3000, unit: .quarter)]),
            Money(cents: 12000)
        )
        // 周付：365 ÷ 7 = 52.14 次 → 52 次（四舍五入）
        XCTAssertEqual(
            SubscriptionOverview.yearlyCost([makeSnapshot(amount: 1000, unit: .week)]),
            Money(cents: 52_143)
        )
        // 每 45 天：365 ÷ 45 = 8.11 次 → 8 次
        XCTAssertEqual(
            SubscriptionOverview.yearlyCost([makeSnapshot(amount: 1000, unit: .day, value: 45)]),
            Money(cents: 8111)
        )
    }

    func testYearlyCostExcludesInactive() {
        let active = makeSnapshot(amount: 2500, unit: .month, status: .active)
        let paused = makeSnapshot(amount: 2500, unit: .month, status: .paused)
        XCTAssertEqual(SubscriptionOverview.yearlyCost([active, paused]), Money(cents: 30000))
    }

    // MARK: - 未来 30 天时间轴

    func testUpcomingIncludesEveryCycleInsideTheWindow() {
        let monthly = makeSnapshot(name: "视频会员", amount: 2500, nextBillingDay: 20261125, unit: .month)
        let weekly = makeSnapshot(name: "报纸", amount: 1000, nextBillingDay: 20261123, unit: .week)

        let items = SubscriptionOverview.upcoming([monthly, weekly], today: today)

        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(
            items.map(\.day.key),
            [20261123, 20261125, 20261130, 20261207, 20261214, 20261221]
        )
        XCTAssertEqual(SubscriptionOverview.upcomingTotal(items), Money(cents: 7500))
    }

    func testUpcomingWindowBoundaryIsInclusive() {
        // 今天 + 30 天 = 2026-12-21
        let onBoundary = makeSnapshot(nextBillingDay: 20261221, unit: .month)
        XCTAssertEqual(
            SubscriptionOverview.upcoming([onBoundary], today: today, within: 30).count,
            1,
            "第 30 天当天仍算在窗口内"
        )

        let outside = makeSnapshot(nextBillingDay: 20261222, unit: .month)
        XCTAssertEqual(
            SubscriptionOverview.upcoming([outside], today: today, within: 30).count,
            0,
            "第 31 天在窗口外"
        )
    }

    func testUpcomingKeepsOverdueNextBilling() {
        let overdue = makeSnapshot(nextBillingDay: 20261118, unit: .month)
        let items = SubscriptionOverview.upcoming([overdue], today: today)

        // 11/18（已过期未处理）与 12/18（窗口内）都应出现
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isOverdue(on: today), "过期未处理的下一期仍应出现在「接下来要扣的钱」里")
        XCTAssertFalse(items[1].isOverdue(on: today))
    }

    func testUpcomingExcludesInactive() {
        let paused = makeSnapshot(nextBillingDay: 20261123, unit: .month, status: .paused)
        let cancelled = makeSnapshot(nextBillingDay: 20261123, unit: .month, status: .cancelled)
        XCTAssertTrue(SubscriptionOverview.upcoming([paused, cancelled], today: today).isEmpty)
    }

    func testUpcomingSortsSameDayByNameForStableOrder() {
        let beta = makeSnapshot(name: "报纸", nextBillingDay: 20261123, unit: .month)
        let alpha = makeSnapshot(name: "云盘", nextBillingDay: 20261123, unit: .month)

        let items = SubscriptionOverview.upcoming([beta, alpha], today: today)

        XCTAssertEqual(items.map(\.name), ["云盘", "报纸"], "同一天按名称排序，列表不能每次刷新都换位置")
    }

    func testUpcomingRespectsItemLimit() {
        let daily = makeSnapshot(nextBillingDay: 20261121, unit: .day, value: 1)
        let items = SubscriptionOverview.upcoming([daily], today: today, within: 30, itemLimit: 5)
        XCTAssertEqual(items.count, 5)
    }

    // MARK: - 构造

    private func makeSnapshot(
        id: UUID = UUID(),
        name: String = "订阅",
        amount: Int64 = 2500,
        nextBillingDay: Int32 = 20261201,
        unit: CycleUnit = .month,
        value: Int = 1,
        status: SubscriptionStatus = .active
    ) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: id,
            name: name,
            amount: amount,
            statusRaw: status.raw,
            autoRenew: true,
            nextBillingDay: nextBillingDay,
            trialEndDay: 0,
            cycleUnit: unit,
            cycleValue: value,
            anchorDay: DateOnly(key: nextBillingDay).day,
            suppressedCycles: [],
            categoryID: nil,
            accountID: nil
        )
    }
}
