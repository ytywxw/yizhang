//
//  SubscriptionListViewModelTests.swift
//  一账Tests / Features
//
//  验证 PRD 4.5 的分组与行内文案——这部分是"纯函数 + 模型"，不需要起 UI：
//  ① 三组固定顺序（生效中 / 已暂停 / 已取消），空组隐藏；
//  ② 生效中按 `nextBillingDay` 升序，同日按名称（列表不能每次刷新都换位置）；
//  ③ 行文案：「11月25日（5天后）」/「（今天）」/「（已逾期 2 天）」/「已取消」；
//  ④ 三个标签的判定：试用中 / 待续费 / 周期异常。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SubscriptionListViewModelTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    func testGroupsUseFixedOrderAndHideEmptyGroups() throws {
        let container = try makeContainer()
        let active = try makeSubscription(in: container, name: "视频会员", nextBillingDay: 20261125)
        let paused = try makeSubscription(in: container, name: "音乐会员", nextBillingDay: 20261123)
        let cancelled = try makeSubscription(in: container, name: "旧报纸", nextBillingDay: 0)

        try pause(paused, in: container)
        try cancel(cancelled, in: container)
        try save(container)

        let groups = SubscriptionListViewModel.makeGroups(
            subscriptions: [cancelled, active, paused],
            today: today
        )

        XCTAssertEqual(groups.map(\.title), ["生效中", "已暂停", "已取消"])
        XCTAssertEqual(groups.map(\.rows.count), [1, 1, 1])

        // 只有生效中 → 只出现一组
        let activeOnly = SubscriptionListViewModel.makeGroups(subscriptions: [active], today: today)
        XCTAssertEqual(activeOnly.map(\.title), ["生效中"])
    }

    func testActiveGroupIsSortedByNextBillingDayThenName() throws {
        let container = try makeContainer()
        let late = try makeSubscription(in: container, name: "云盘", nextBillingDay: 20261221)
        let soon = try makeSubscription(in: container, name: "视频会员", nextBillingDay: 20261122)
        let sameDayB = try makeSubscription(in: container, name: "报纸", nextBillingDay: 20261125)
        let sameDayA = try makeSubscription(in: container, name: "QQ音乐", nextBillingDay: 20261125)

        let groups = SubscriptionListViewModel.makeGroups(
            subscriptions: [late, sameDayB, soon, sameDayA],
            today: today
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.name), ["视频会员", "QQ音乐", "报纸", "云盘"])
    }

    func testNextBillingTextCoversTodayFutureOverdueAndCancelled() throws {
        let container = try makeContainer()

        let dueToday = try makeSubscription(in: container, name: "今天", nextBillingDay: 20261121)
        let inFiveDays = try makeSubscription(in: container, name: "五天后", nextBillingDay: 20261126)
        let overdue = try makeSubscription(in: container, name: "逾期", nextBillingDay: 20261119)
        let cancelled = try makeSubscription(in: container, name: "取消", nextBillingDay: 0)
        try cancel(cancelled, in: container)

        XCTAssertEqual(
            SubscriptionListViewModel.nextBillingText(for: dueToday, today: today),
            "11月21日（今天）"
        )
        XCTAssertEqual(
            SubscriptionListViewModel.nextBillingText(for: inFiveDays, today: today),
            "11月26日（5天后）"
        )
        XCTAssertEqual(
            SubscriptionListViewModel.nextBillingText(for: overdue, today: today),
            "11月19日（已逾期 2 天）"
        )
        XCTAssertEqual(
            SubscriptionListViewModel.nextBillingText(for: cancelled, today: today),
            "已取消"
        )
    }

    func testRowFlagsCoverTrialAwaitingRenewalAndTruncation() throws {
        let container = try makeContainer()
        let gym = try makeSubscription(
            in: container,
            name: "健身房",
            amount: 19900,
            nextBillingDay: 20261119,
            autoRenew: false,
            trialEndDay: 20261126
        )

        let row = SubscriptionListViewModel.makeRow(gym, today: today, isTruncated: true)

        XCTAssertTrue(row.isAwaitingRenewal, "不自动续费且已到期 → 待续费")
        XCTAssertTrue(row.isTrial, "试用结束日在未来 → 试用中")
        XCTAssertEqual(row.trialText, "试用中，5 天后开始扣费")
        XCTAssertTrue(row.isTruncated, "命中 24 笔上限 → 周期异常")
        XCTAssertEqual(row.amountPerCycleText, "¥199.00 / 月")
        XCTAssertEqual(row.nextBillingText, "11月19日（已逾期 2 天）")
        XCTAssertEqual(row.iconName, "arrow.triangle.2.circlepath", "空图标兜底为订阅图标（在白名单内）")
    }

    func testAutoRenewingSubscriptionIsNotAwaitingRenewal() throws {
        let container = try makeContainer()
        let video = try makeSubscription(in: container, name: "视频会员", nextBillingDay: 20261119)

        let row = SubscriptionListViewModel.makeRow(video, today: today)

        XCTAssertFalse(row.isAwaitingRenewal, "自动续费的订阅到期后由扫描记账，不算「待续费」")
        XCTAssertFalse(row.isTrial)
        XCTAssertNil(row.trialText)
    }

    // MARK: - 工具

    private func makeContainer() throws -> ModelContainer {
        try ModelContainerFactory.make(inMemory: true)
    }

    private func makeSubscription(
        in container: ModelContainer,
        name: String,
        amount: Int64 = 2500,
        nextBillingDay: Int32,
        autoRenew: Bool = true,
        trialEndDay: Int32 = 0
    ) throws -> Subscription {
        let subscription = Subscription()
        subscription.id = UUID()
        subscription.name = name
        subscription.amount = amount
        subscription.cycleUnit = .month
        subscription.cycleValue = 1
        subscription.billingAnchorDay = max(DateOnly(key: nextBillingDay).day, 1)
        subscription.firstBillingDay = nextBillingDay
        subscription.nextBillingDay = nextBillingDay
        subscription.autoRenew = autoRenew
        subscription.trialEndDay = trialEndDay
        subscription.status = .active
        container.mainContext.insert(subscription)
        try container.mainContext.save()
        return subscription
    }

    private func pause(_ subscription: Subscription, in container: ModelContainer) throws {
        subscription.status = .paused
        try container.mainContext.save()
    }

    private func cancel(_ subscription: Subscription, in container: ModelContainer) throws {
        subscription.status = .cancelled
        subscription.nextBillingDay = 0
        try container.mainContext.save()
    }

    private func save(_ container: ModelContainer) throws {
        try container.mainContext.save()
    }
}
