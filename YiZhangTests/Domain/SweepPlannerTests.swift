//
//  SweepPlannerTests.swift
//  一账Tests / Domain
//
//  这是整个项目**最值钱的一组测试**：`SweepPlanner` 是纯函数，不需要 `ModelContainer`，
//  所以 R-SUB-3/4/5/6/7/8 的每条规则都能在这里逐条钉死。
//
//  刻意覆盖的 8 个场景（对应 PRD 4.2 / 4.3）：
//  ① occurredDay 必须用**应扣日**，不是今天（R-SUB-4①）；
//  ② 补漏：落后多期时每期一笔，日期逐期推进（R-SUB-5）；
//  ③ 「每两周」同月扣两次，两个幂等键必须不同（§3.7 D2，风险 R5）；
//  ④ 幂等键已存在 → 跳过该期但**日期继续推进**（否则永远卡在到期）；
//  ⑤ 24 笔上限是**笔**级、跨订阅合计（R-SUB-5）；
//  ⑥ 被抑制的周期不生成账目，但日期前进（R-SUB-DEL A）；
//  ⑦ 金额为 0 只推进不生成（E-9）；
//  ⑧ 不自动续费只产出待续费提示（R-SUB-6）。
//

import XCTest
@testable import YiZhang

final class SweepPlannerTests: XCTestCase {

    /// 固定"今天"：2026-11-21（周六）。
    private let today = DateOnly(key: 20261121)

    // MARK: - ① 应扣日 vs 今天

    func testGeneratesOneActionOnDueDayNotToday() {
        let id = UUID()
        let snapshot = makeSnapshot(
            id: id,
            amount: 2500,
            nextBillingDay: 20261118,
            cycleUnit: .month,
            cycleValue: 1,
            anchorDay: 18
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertEqual(plan.actions.count, 1)
        guard let action = plan.actions.first else { return XCTFail("应生成 1 笔") }
        XCTAssertEqual(action.occurredDay, 20261118, "occurredDay 必须是应扣日，绝不能是今天")
        XCTAssertNotEqual(action.occurredDay, today.key)
        XCTAssertEqual(action.subscriptionID, id)
        XCTAssertEqual(action.amount, 2500)
        XCTAssertEqual(action.cycleKey, "2026-11")
        XCTAssertEqual(action.uniqueKey, SubscriptionSnapshot.makeUniqueKey(subscriptionID: id, cycleKey: "2026-11"))
        XCTAssertEqual(action.nextBillingDayAfter, 20261218)
        XCTAssertEqual(action.draft.note, "订阅：视频会员")
        XCTAssertEqual(action.draft.source, .subscription)
        XCTAssertEqual(plan.advances.count, 0, "有账目时日期由 action 携带，不再单独 advance")
        XCTAssertFalse(plan.isTruncated)
    }

    // MARK: - ② 补漏

    func testCatchUpGeneratesOneEntryPerMissedCycle() {
        let snapshot = makeSnapshot(
            nextBillingDay: 20260825,
            cycleUnit: .month,
            cycleValue: 1,
            anchorDay: 25
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertEqual(plan.actions.map(\.occurredDay), [20260825, 20260925, 20261025])
        XCTAssertEqual(plan.actions.last?.nextBillingDayAfter, 20261125, "最后一期推进后应晚于今天")
        XCTAssertTrue(plan.actions.allSatisfy { $0.nextBillingDayAfter > $0.occurredDay })
    }

    // MARK: - ③ 每两周：同月两次，两个幂等键

    func testEveryTwoWeeksChargesTwiceInSameMonthWithDistinctKeys() {
        let id = UUID()
        let snapshot = makeSnapshot(
            id: id,
            nextBillingDay: 20261101,
            cycleUnit: .week,
            cycleValue: 2,
            anchorDay: 1
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertEqual(plan.actions.map(\.occurredDay), [20261101, 20261115])
        XCTAssertEqual(plan.actions.map(\.cycleKey), ["d-20261101", "d-20261115"])
        XCTAssertEqual(Set(plan.actions.map(\.uniqueKey)).count, 2, "同月两次扣费必须有两个不同幂等键")
        XCTAssertEqual(plan.actions.last?.nextBillingDayAfter, 20261129)
    }

    // MARK: - ④ 幂等键已存在

    func testExistingKeyIsSkippedButDateStillAdvances() {
        let id = UUID()
        let snapshot = makeSnapshot(id: id, nextBillingDay: 20261118, anchorDay: 18)
        let existingKey = snapshot.uniqueKey(for: DateOnly(key: 20261118))

        let plan = SweepPlanner.plan(
            snapshots: [snapshot],
            today: today,
            existingKeys: [existingKey]
        )

        XCTAssertTrue(plan.actions.isEmpty, "幂等命中不得再生成")
        XCTAssertEqual(plan.skippedDuplicateCount, 1)
        XCTAssertEqual(plan.advances.count, 1, "没有账目时必须单独推进日期，否则永远卡在到期")
        XCTAssertEqual(plan.advances.first?.nextBillingDay, 20261218)
        XCTAssertEqual(plan.advances.first?.lastCycleKey, "2026-11")
    }

    // MARK: - ⑤ 24 笔上限

    func testTwentyFourCapStopsThisSubscriptionAndMarksTruncated() {
        let id = UUID()
        let snapshot = makeSnapshot(
            id: id,
            nextBillingDay: 20261023,
            cycleUnit: .day,
            cycleValue: 1,
            anchorDay: 23
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertEqual(plan.actions.count, 24, "单次扫描最多 24 笔")
        XCTAssertEqual(plan.actions.first?.occurredDay, 20261023)
        XCTAssertEqual(plan.actions.last?.occurredDay, 20261115)
        XCTAssertEqual(plan.truncatedSubscriptionIDs, [id])
        XCTAssertTrue(plan.isTruncated)
        XCTAssertEqual(
            plan.advances.count, 0,
            "被截断时日期停在未处理的那一期，由下一笔 action 的 nextBillingDayAfter 表达"
        )
        XCTAssertEqual(plan.actions.last?.nextBillingDayAfter, 20261116, "下次扫描从这里继续")
    }

    func testCapIsGlobalAcrossSubscriptions() {
        // 第一个订阅落后 2 期，正好用满 2 笔上限；第二个订阅因此被截断
        let first = makeSnapshot(nextBillingDay: 20261001, cycleUnit: .month, anchorDay: 1)
        let second = makeSnapshot(nextBillingDay: 20261118, cycleUnit: .month, anchorDay: 18)

        let plan = SweepPlanner.plan(
            snapshots: [first, second],
            today: today,
            existingKeys: [],
            limit: 2
        )

        XCTAssertEqual(plan.actions.count, 2, "上限按笔计、跨订阅合计")
        XCTAssertEqual(plan.actions.map(\.subscriptionID), [first.id, first.id])
        XCTAssertEqual(plan.truncatedSubscriptionIDs, [second.id], "第二个订阅被截断")
    }

    // MARK: - ⑥ 被抑制的周期

    func testSuppressedCycleIsSkippedButDateAdvances() {
        let snapshot = makeSnapshot(
            nextBillingDay: 20261118,
            anchorDay: 18,
            suppressedCycles: ["2026-11"]
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertEqual(plan.skippedDuplicateCount, 0, "被抑制不是幂等命中，不应计入 skipped")
        XCTAssertEqual(plan.advances.map(\.nextBillingDay), [20261218])
    }

    // MARK: - ⑦ 金额为 0

    func testZeroAmountGeneratesNothingButAdvancesDate() {
        let snapshot = makeSnapshot(amount: 0, nextBillingDay: 20261118, anchorDay: 18)

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertTrue(plan.actions.isEmpty, "E-9：金额为 0 不生成账目")
        XCTAssertEqual(plan.advances.map(\.nextBillingDay), [20261218])
    }

    // MARK: - ⑧ 不自动续费

    func testAutoRenewFalseProducesNoticeOnly() {
        let id = UUID()
        let snapshot = makeSnapshot(
            id: id,
            nextBillingDay: 20261118,
            anchorDay: 18,
            autoRenew: false
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertTrue(plan.actions.isEmpty, "R-SUB-6：不自动续费绝不生成账目")
        XCTAssertTrue(plan.advances.isEmpty, "日期也不能推进，否则「待续费」状态立刻消失")
        XCTAssertEqual(plan.notices.count, 1)
        XCTAssertEqual(plan.notices.first?.subscriptionID, id)
        XCTAssertEqual(plan.notices.first?.dueDay, 20261118)
        XCTAssertEqual(plan.notices.first?.amountMoney, Money(cents: 2500))
    }

    func testAutoRenewFalseButNotDueProducesNothing() {
        let snapshot = makeSnapshot(
            nextBillingDay: 20261218,
            anchorDay: 18,
            autoRenew: false
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - 其它边界

    func testTrialInProgressGeneratesNothing() {
        let snapshot = makeSnapshot(
            nextBillingDay: 20261121,
            anchorDay: 21,
            trialEndDay: 20261205
        )

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertTrue(plan.isEmpty, "E-1：试用期内不生成任何账目")
    }

    func testPausedAndCancelledGenerateNothing() {
        let paused = makeSnapshot(nextBillingDay: 20261101, anchorDay: 1, status: .paused)
        let cancelled = makeSnapshot(nextBillingDay: 20261101, anchorDay: 1, status: .cancelled)

        let plan = SweepPlanner.plan(snapshots: [paused, cancelled], today: today, existingKeys: [])

        XCTAssertTrue(plan.isEmpty)
    }

    func testAnchorDayIsPreservedAcrossCatchUp() {
        // R-SUB-8：1/31 → 2/28 → 3/31（不是 3/28）
        let snapshot = makeSnapshot(
            nextBillingDay: 20260131,
            cycleUnit: .month,
            cycleValue: 1,
            anchorDay: 31
        )

        let plan = SweepPlanner.plan(
            snapshots: [snapshot],
            today: DateOnly(key: 20260331),
            existingKeys: []
        )

        XCTAssertEqual(plan.actions.map(\.occurredDay), [20260131, 20260228, 20260331])
        XCTAssertEqual(plan.actions.last?.nextBillingDayAfter, 20260430)
    }

    func testDuplicateSnapshotsInSamePlanAreProcessedOnce() {
        let snapshot = makeSnapshot(nextBillingDay: 20261118, anchorDay: 18)

        let plan = SweepPlanner.plan(
            snapshots: [snapshot, snapshot],
            today: today,
            existingKeys: []
        )

        XCTAssertEqual(plan.actions.count, 1, "同一订阅在一次扫描里只处理一次")
    }

    func testZeroDayIsIgnored() {
        let snapshot = makeSnapshot(nextBillingDay: 0, anchorDay: 1)

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: today, existingKeys: [])

        XCTAssertTrue(plan.isEmpty)
    }

    func testInvalidTodayProducesEmptyPlan() {
        let snapshot = makeSnapshot(nextBillingDay: 20261118, anchorDay: 18)

        let plan = SweepPlanner.plan(snapshots: [snapshot], today: .zero, existingKeys: [])

        XCTAssertTrue(plan.isEmpty)
    }

    // MARK: - 构造

    private func makeSnapshot(
        id: UUID = UUID(),
        name: String = "视频会员",
        amount: Int64 = 2500,
        nextBillingDay: Int32,
        cycleUnit: CycleUnit = .month,
        cycleValue: Int = 1,
        anchorDay: Int,
        status: SubscriptionStatus = .active,
        autoRenew: Bool = true,
        trialEndDay: Int32 = 0,
        suppressedCycles: Set<String> = []
    ) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: id,
            name: name,
            amount: amount,
            statusRaw: status.raw,
            autoRenew: autoRenew,
            nextBillingDay: nextBillingDay,
            trialEndDay: trialEndDay,
            cycleUnit: cycleUnit,
            cycleValue: cycleValue,
            anchorDay: anchorDay,
            suppressedCycles: suppressedCycles,
            categoryID: nil,
            accountID: nil
        )
    }
}
