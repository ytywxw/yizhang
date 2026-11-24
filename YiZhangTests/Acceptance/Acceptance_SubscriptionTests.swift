//
//  Acceptance_SubscriptionTests.swift
//  YiZhangTests / Acceptance
//
//  验收场景 A1 / A3 / A4 / A5 / A6 / A7 / A8：订阅结算扫描的全部关键行为。
//  每个用例都用"真实容器 + 真实服务"跑，且不依赖系统当前时间（统一用 2026-11-21）。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class Acceptance_SubscriptionTests: XCTestCase {

    private let today = AcceptanceToday.value

    // MARK: - A1 冷启动补漏：3 个月前起扣、不补录 → 扫出 3 笔，日期各为应扣日

    func testA1_CatchUpAcrossRelaunchWritesOneEntryPerDueDay() throws {
        let first = try AcceptanceWorld.boot()
        let account = try first.firstAccount()

        let created = try first.env.subscription.create(
            SubscriptionDraft(
                name: "视频会员",
                amount: 2500,
                firstBillingDay: 20260825,
                categoryID: PresetCatalog.subscriptionCategoryID,
                accountID: account.id
            ),
            today: today
        )

        // E-5：新建时**默认不补录**，所以此刻账本应该是空的
        XCTAssertEqual(try first.entries().count, 0, "新建订阅不得静默补账（E-5 默认不补）")
        XCTAssertEqual(created.nextBillingDay, 20260825)

        // 模拟用户关掉 App 再打开：同一份存储、全新的 context 与服务实例
        let relaunched = try AcceptanceWorld.boot(reusing: first.container)
        let report = relaunched.env.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 3, "落后 3 期应补 3 笔")
        XCTAssertEqual(report.failedSubscriptionIDs, [])

        let entries = try relaunched.entries()
        XCTAssertEqual(
            entries.map(\.occurredDay).sorted(),
            [20260825, 20260925, 20261025],
            "每一笔的 occurredDay 必须是各自的应扣日（R-SUB-4①），不是今天"
        )
        XCTAssertTrue(
            entries.allSatisfy { $0.occurredDay != today.key },
            "补漏生成的账目绝不能全落在今天"
        )
        XCTAssertTrue(entries.allSatisfy { $0.amount == 2500 })
        XCTAssertTrue(entries.allSatisfy { $0.source == .subscription })
        XCTAssertTrue(entries.allSatisfy { $0.sourceRefID == created.subscriptionID })
        XCTAssertTrue(entries.allSatisfy { $0.note == "订阅：视频会员" })
        XCTAssertTrue(
            entries.allSatisfy { $0.category?.id == PresetCatalog.subscriptionCategoryID },
            "分类继承订阅（默认「订阅服务」）"
        )
        XCTAssertEqual(
            Set(entries.compactMap(\.sourceCycleKey)),
            ["2026-08", "2026-09", "2026-10"],
            "月付的周期键是 yyyy-MM"
        )

        let subscription = try XCTUnwrap(
            try relaunched.env.subscription.subscription(id: created.subscriptionID)
        )
        XCTAssertEqual(subscription.nextBillingDay, 20261125, "从原 nextBillingDay 推进，不是从今天")
        XCTAssertGreaterThan(subscription.nextBillingDay, today.key, "扫完必须已推进到未来")

        // 幂等：再扫一次不得多出账目
        let second = relaunched.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(try relaunched.entries().count, 3)
    }

    // MARK: - A3 删账 A 分支：删该期 + 抑制 → 不再生成，日期不回退

    func testA3_DeleteBranchA_SuppressesCycleWithoutRollingBackSchedule() async throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        _ = try world.env.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260825, accountID: account.id),
            today: today
        )
        XCTAssertEqual(world.env.sweep.sweep(today: today, force: true).inserted, 3)

        let entries = try world.entries()
        let second = try XCTUnwrap(entries.first { $0.occurredDay == 20260925 })
        let cycleKey = try XCTUnwrap(second.sourceCycleKey)
        let subscriptionID = try XCTUnwrap(second.sourceRefID)
        XCTAssertEqual(cycleKey, "2026-09")

        // 用户在详情页选 A「只删这笔账」：
        // 软删 + 把该周期写进 suppressedCycles，nextBillingDay 不回退。
        // （生产中这两步由 EntryDetailView.deleteAndSuppress() 串起来，此处逐字复现）
        let deleted = await world.env.ledger.delete(id: second.id)
        let token = try XCTUnwrap(deleted)
        XCTAssertEqual(token.snapshot.occurredDay, 20260925)
        XCTAssertTrue(try world.env.subscription.suppress(cycleKey: cycleKey, of: subscriptionID))

        let subscription = try XCTUnwrap(try world.env.subscription.subscription(id: subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261125, "A 分支：下次扣费日不回退")
        XCTAssertTrue(subscription.suppressedCycleSet.contains("2026-09"))
        XCTAssertEqual(try world.entries().count, 2)
        XCTAssertEqual(try world.entries(includeDeleted: true).count, 3, "A 分支是软删，记录仍在")

        // 重新扫描：该期不得复活
        let resweep = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(resweep.inserted, 0, "被抑制的周期不得再生成")
        XCTAssertEqual(try world.entries().count, 2)

        // 更强的验证：把日期「假回退」到该周期后再扫一次，抑制表仍应挡住复活
        try world.env.subscription.update(
            id: subscriptionID,
            changing: SubscriptionChanges(nextBillingDay: 20260925),
            today: today
        )
        let rewoundSweep = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(rewoundSweep.inserted, 0, "抑制表必须挡住「日期回到过去」造成的复活")
        let finalSubscription = try XCTUnwrap(
            try world.env.subscription.subscription(id: subscriptionID)
        )
        XCTAssertEqual(finalSubscription.nextBillingDay, 20261125, "跳过被抑制期后必须继续推进到未来")
        XCTAssertFalse(
            try world.entries().contains { $0.occurredDay == 20260925 },
            "该期账目不应重新出现"
        )
    }

    // MARK: - A4 删账 B 分支：硬删 + 回退 → 重新扫描该期重新出现

    func testA4_DeleteBranchB_RevertsScheduleAndEntryComesBack() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        _ = try world.env.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260825, accountID: account.id),
            today: today
        )
        XCTAssertEqual(world.env.sweep.sweep(today: today, force: true).inserted, 3)

        let second = try XCTUnwrap(try world.entries().first { $0.occurredDay == 20260925 })
        let cycleKey = try XCTUnwrap(second.sourceCycleKey)
        let subscriptionID = try XCTUnwrap(second.sourceRefID)

        // 用户在详情页选 B「删这笔账，并让订阅重新生成」：
        // **先硬删**（否则幂等键残留会让该期永不重生，风险 R8），再回退日期。
        XCTAssertTrue(world.env.ledger.hardDelete(id: second.id), "B 分支必须硬删")
        XCTAssertEqual(try world.entries(includeDeleted: true).count, 2, "硬删后不留任何记录")

        let rewound = try world.env.subscription.revertCycle(cycleKey: cycleKey, of: subscriptionID)
        XCTAssertEqual(rewound?.key, 20260925, "B 分支把下次扣费日退回本期应扣日")

        let subscription = try XCTUnwrap(try world.env.subscription.subscription(id: subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20260925)
        XCTAssertEqual(subscription.billingAnchorDay, 25, "锚定日跟着回退日期走（25 号）")
        XCTAssertFalse(subscription.suppressedCycleSet.contains("2026-09"), "B 分支要解除抑制")

        // 重新扫描：该期必须重新出现
        let resweep = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(resweep.inserted, 1, "B 分支后该期必须重新生成（R8 的核心验收）")

        let entries = try world.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(
            entries.contains { $0.occurredDay == 20260925 },
            "重新生成的那笔必须落在原应扣日 2026-09-25"
        )
        let regenerated = try XCTUnwrap(entries.first { $0.occurredDay == 20260925 })
        XCTAssertEqual(regenerated.amount, 2500)
        XCTAssertEqual(regenerated.sourceCycleKey, "2026-09")

        let after = try XCTUnwrap(try world.env.subscription.subscription(id: subscriptionID))
        XCTAssertEqual(after.nextBillingDay, 20261125, "重生之后日期再次推进到未来")
    }

    // MARK: - A5 暂停 2 个月后恢复：不得补暂停期的账

    func testA5_PauseThenResumeDoesNotBackfillPausedMonths() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let created = try world.env.subscription.create(
            SubscriptionDraft(name: "健身房月卡", amount: 30000, firstBillingDay: 20260915, accountID: account.id),
            today: DateOnly(key: 20260915)
        )

        try world.env.subscription.pause(id: created.subscriptionID)
        let paused = try XCTUnwrap(try world.env.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.nextBillingDay, 20260915, "暂停保留下次扣费日不动（E-4）")

        // 暂停期跨 10、11 两个月，到 11-15 恢复
        let resumeDay = DateOnly(key: 20261115)
        try world.env.subscription.resume(id: created.subscriptionID, today: resumeDay)

        let resumed = try XCTUnwrap(try world.env.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(resumed.status, .active)
        XCTAssertEqual(resumed.nextBillingDay, 20261215, "恢复时顺延到「今天之后的第一个周期日」")
        XCTAssertGreaterThan(resumed.nextBillingDay, resumeDay.key)

        // 关键断言：暂停的 9/15、10/15、11/15 三期一分钱都不能补
        let report = world.env.sweep.sweep(today: resumeDay, force: true)
        XCTAssertEqual(report.inserted, 0, "暂停期不得补账")
        XCTAssertEqual(try world.entries().count, 0, "恢复后账本必须还是空的")

        // 到期日真正到来时才生成 1 笔
        let dueDay = DateOnly(key: 20261215)
        XCTAssertEqual(world.env.sweep.sweep(today: dueDay, force: true).inserted, 1)
        let entries = try world.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.occurredDay, 20261215)
    }

    // MARK: - A6 试用期：试用内不生成，过了试用才生成

    func testA6_TrialPeriodBlocksGenerationUntilTrialEnds() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let created = try world.env.subscription.create(
            SubscriptionDraft(
                name: "AI 工具",
                amount: 9900,
                firstBillingDay: 20261101,
                trialEndDay: 20261231,
                accountID: account.id
            ),
            today: today
        )
        XCTAssertEqual(created.nextBillingDay, 20261231, "E-1：试用中，下次扣费日对齐到试用结束日")

        let beforeTrial = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(beforeTrial.inserted, 0, "试用期内不得生成任何账目")
        XCTAssertEqual(try world.entries().count, 0)

        // 把「今天」推到试用结束之后
        let afterTrial = DateOnly(key: 20270105)
        let report = world.env.sweep.sweep(today: afterTrial, force: true)
        XCTAssertEqual(report.inserted, 1, "试用结束后才生成")

        let entries = try world.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.occurredDay, 20261231, "首期落在试用结束日当天")

        let subscription = try XCTUnwrap(try world.env.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20270131)
    }

    // MARK: - A7 周期漂移：1/31 锚定，连推 5 期应是 2/28、3/31、4/30、5/31、6/30

    func testA7_MonthEndAnchorDoesNotDrift() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let endOfJune = DateOnly(key: 20260630)

        _ = try world.env.subscription.create(
            SubscriptionDraft(name: "月末扣费", amount: 1000, firstBillingDay: 20260131, accountID: account.id),
            today: endOfJune
        )
        let report = world.env.sweep.sweep(today: endOfJune, force: true)
        XCTAssertEqual(report.inserted, 6, "1/31 起扣到 6/30 共 6 期")

        let days = try world.entries().map(\.occurredDay).sorted()
        XCTAssertEqual(
            days,
            [20260131, 20260228, 20260331, 20260430, 20260531, 20260630],
            "期末对齐：2 月夹到 28、3 月要回到 31，绝不出现 3/28"
        )
        XCTAssertFalse(days.contains(20260328), "出现 3/28 就是永久漂移（R-SUB-8）")
    }

    // MARK: - A8 每两周：同一自然月两次扣费 → 2 笔（D2 的 d-yyyyMMdd 去重键）

    func testA8_BiweeklySubscriptionChargesTwiceInOneMonth() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()

        _ = try world.env.subscription.create(
            SubscriptionDraft(
                name: "双周订阅",
                amount: 1500,
                cycleUnit: .week,
                cycleValue: 2,
                firstBillingDay: 20261102,
                accountID: account.id
            ),
            today: today
        )

        let report = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 2, "11/2 与 11/16 两次扣费，两笔独立账目")

        let entries = try world.entries()
        XCTAssertEqual(entries.map(\.occurredDay).sorted(), [20261102, 20261116])
        XCTAssertEqual(
            Set(entries.compactMap(\.sourceCycleKey)),
            ["d-20261102", "d-20261116"],
            "day/week 周期必须精确到日，否则同月第二次扣费会被静默丢弃（风险 R5）"
        )

        let subscriptionID = try XCTUnwrap(entries[0].sourceRefID)
        let subscription = try XCTUnwrap(try world.env.subscription.subscription(id: subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261130)

        // 再扫一次：幂等，不得变成 3 笔或 4 笔
        XCTAssertEqual(world.env.sweep.sweep(today: today, force: true).inserted, 0)
        XCTAssertEqual(try world.entries().count, 2)
    }
}
