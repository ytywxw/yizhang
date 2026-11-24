//
//  SubscriptionRevertTests.swift
//  一账Tests / Persistence
//
//  T14 删账双分支的落库验收：
//  ① B 分支「回退周期」把 `nextBillingDay` 退回该期应扣日、清 `lastSweptCycleKey`、
//     并把周期键从 `suppressedCycles` 里摘掉；
//  ② **硬删之后同一周期键能真的重新生成**（真跑一次 `sweep()`，不是只查状态）；
//  ③ A 分支（抑制）才是"别再补"：抑制的周期扫描永远不生成；
//  ④ 顺序不能反：只回退不硬删，软删记录仍占着幂等键（R-SUB-7），扫描照样跳过——
//     这正是 B 分支必须"先硬删、后回退"的原因（风险 R8）；
//  ⑤ 月末订阅回退时不改锚定日，否则 1/31 → 2/28 之后会永久漂到 28 号（R-SUB-8）。
//
//  这些用例必须用真容器：要验证"幂等键被谁占着"，只能真的写进 SQLite 再扫一次。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SubscriptionRevertTests: XCTestCase {

    /// 固定"今天"：2026-11-21。
    private let today = DateOnly(key: 20261121)

    // MARK: - ① 回退周期本身

    func testRevertCycleMovesNextBillingDayBackToDueDay() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)

        let before = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(before.nextBillingDay, 20261215, "扫描后日期已推进到 12/15")
        XCTAssertEqual(before.lastSweptCycleKey, "2026-11")

        let reverted = try sut.subscription.revertCycle(cycleKey: "2026-11", of: created.subscriptionID)

        XCTAssertEqual(reverted, DateOnly(key: 20261115), "返回值就是该期应扣日")
        let after = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(after.nextBillingDay, 20261115, "B 分支：下次扣费日退回该期应扣日")
        XCTAssertNil(after.lastSweptCycleKey, "回退后必须清掉「最后扫描到的周期」，否则排查时会被误导")
        XCTAssertEqual(after.billingAnchorDay, 15, "非月末订阅：锚定日不变（写了也是同一个值）")
    }

    func testRevertCycleRemovesCycleKeyFromSuppressedCycles() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)

        // 先制造"这一期被抑制过"的状态：用户曾经删过、后来又想让它回来
        XCTAssertTrue(try sut.subscription.suppress(cycleKey: "2026-11", of: created.subscriptionID))
        let suppressed = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertTrue(suppressed.suppressedCycleSet.contains("2026-11"))

        _ = try sut.subscription.revertCycle(cycleKey: "2026-11", of: created.subscriptionID)

        let after = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertFalse(
            after.suppressedCycleSet.contains("2026-11"),
            "B 分支的语义是「当作没扣过」，抑制表也必须一起摘掉"
        )
        XCTAssertTrue(after.suppressedCycleSet.isEmpty)
    }

    // MARK: - ② 硬删之后能重新生成（本条是 B 分支的核心验收）

    func testHardDeleteThenRevertRegeneratesTheSameCycle() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(try liveEntries(sut.writer).count, 3, "9/15、10/15、11/15")

        let target = try XCTUnwrap(try liveEntries(sut.writer).first { $0.occurredDay == 20261115 })
        let cycleKey = try XCTUnwrap(target.sourceCycleKey)
        let uniqueKey = try XCTUnwrap(target.sourceCycleUniqueKey)
        XCTAssertEqual(cycleKey, "2026-11")

        // ① 先硬删（B 分支的顺序：删在前，回退在后）
        XCTAssertTrue(sut.ledger.hardDelete(id: target.id))
        XCTAssertEqual(
            try sut.writer.count(QueryDescriptors.allEntries()), 2,
            "硬删必须把行真的去掉，不能留软删记录占着幂等键（R-SUB-7）"
        )

        // ② 再回退周期
        _ = try sut.subscription.revertCycle(cycleKey: cycleKey, of: created.subscriptionID)

        // ③ 真跑一次扫描，看这一期能不能回来
        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 1, "硬删 + 回退之后，同一周期必须能重新生成")
        XCTAssertEqual(report.skipped, 0, "键已被硬删腾空，不该有任何幂等命中")
        let regenerated = try XCTUnwrap(try liveEntries(sut.writer).first { $0.occurredDay == 20261115 })
        XCTAssertEqual(regenerated.sourceCycleUniqueKey, uniqueKey, "重新生成的账目要占回同一个幂等键")
        XCTAssertEqual(regenerated.amount, target.amount)
        XCTAssertEqual(regenerated.source, .subscription)
        XCTAssertEqual(regenerated.note, "订阅：视频会员")
        XCTAssertEqual(try liveEntries(sut.writer).count, 3, "账目总数回到 3")

        let after = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(after.nextBillingDay, 20261215, "重放之后日期回到 12/15")
    }

    // MARK: - ④ 顺序不能反：只回退不硬删，键仍被占着

    func testRevertWithoutHardDeleteCannotRegenerateBecauseKeyStaysOccupied() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)

        let target = try XCTUnwrap(try liveEntries(sut.writer).first { $0.occurredDay == 20261115 })
        // 只软删（A 分支的删法）+ 回退，故意不硬删
        _ = try sut.writer.softDelete(id: target.id, at: Date())
        _ = try sut.subscription.revertCycle(cycleKey: "2026-11", of: created.subscriptionID)

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(
            report.inserted, 0,
            "软删记录仍然占着幂等键，扫描永远跳过——这就是 B 分支必须先硬删的原因（R8）"
        )
        XCTAssertEqual(report.skipped, 1, "这一期是被幂等命中挡掉的，不是被抑制挡掉的")
        XCTAssertEqual(try liveEntries(sut.writer).count, 2, "用户看到的账目仍然只有 2 笔")
    }

    // MARK: - ③ A 分支：抑制的周期不生成

    func testSuppressedCycleIsNeverGenerated() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        // 先抑制 11 月这一期，再扫
        XCTAssertTrue(try sut.subscription.suppress(cycleKey: "2026-11", of: created.subscriptionID))

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 2, "9/15、10/15 生成，11/15 被抑制")
        let days = try liveEntries(sut.writer).map(\.occurredDay).sorted()
        XCTAssertEqual(days, [20260915, 20261015])
        XCTAssertFalse(days.contains(20261115), "A 分支：这一期不会再补")

        let after = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(after.nextBillingDay, 20261215, "被抑制也要推进日期，否则会卡死在这一期")
    }

    // MARK: - ⑤ 月末：回退不改锚定日（R-SUB-8）

    func testMonthEndRevertKeepsAnchorAndDoesNotDrift() throws {
        let sut = try makeSUT()
        // 1/31 建、锚定 31：周期是 1/31 → 2/28 → 3/31 → 4/30 …
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "月末订阅", amount: 1000, firstBillingDay: 20260131),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)

        let swept = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(swept.billingAnchorDay, 31)
        XCTAssertEqual(swept.nextBillingDay, 20261130, "1/31 … 10/31 生成后，下一期是 11/30")

        let february = try XCTUnwrap(try liveEntries(sut.writer).first { $0.occurredDay == 20260228 })
        XCTAssertTrue(sut.ledger.hardDelete(id: february.id))
        _ = try sut.subscription.revertCycle(cycleKey: "2026-02", of: created.subscriptionID)

        let reverted = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(reverted.nextBillingDay, 20260228, "2 月按当月天数夹到 28")
        XCTAssertEqual(
            reverted.billingAnchorDay, 31,
            "锚定日必须保持 31：写成 28 会让下一期变成 3/28 并永久漂走（R-SUB-8，偏差 D20）"
        )

        let report = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 1, "2/28 重新生成")
        XCTAssertEqual(report.skipped, 8, "3/31 … 10/31 共 8 期幂等命中")
        XCTAssertNotNil(try liveEntries(sut.writer).first { $0.occurredDay == 20260228 })

        let after = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(after.nextBillingDay, 20261130, "重放之后仍然是月末，不能漂到 11/28")
    }

    // MARK: - ⑥ 按天/按周的键格式（d-yyyyMMdd）

    func testRevertCycleParsesDayKeyForWeeklySubscription() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(
                name: "每周鲜花",
                amount: 3900,
                cycleUnit: .week,
                cycleValue: 1,
                firstBillingDay: 20261107
            ),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)
        // 11/7、11/14、11/21（今天当天也算到期）
        XCTAssertEqual(try liveEntries(sut.writer).count, 3)

        let target = try XCTUnwrap(try liveEntries(sut.writer).first { $0.occurredDay == 20261114 })
        XCTAssertEqual(target.sourceCycleKey, "d-20261114", "day / week 的键是 d-yyyyMMdd")

        XCTAssertTrue(sut.ledger.hardDelete(id: target.id))
        let reverted = try sut.subscription.revertCycle(cycleKey: "d-20261114", of: created.subscriptionID)
        XCTAssertEqual(reverted, DateOnly(key: 20261114))

        let report = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 1, "11/14 重新生成")
        XCTAssertEqual(report.skipped, 1, "11/21 幂等命中")
        XCTAssertNotNil(try liveEntries(sut.writer).first { $0.occurredDay == 20261114 })
    }

    // MARK: - ⑦ 边界

    func testRevertCycleReturnsNilForUnparsableKey() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)

        XCTAssertNil(try sut.subscription.revertCycle(cycleKey: "not-a-cycle", of: created.subscriptionID))
        XCTAssertNil(try sut.subscription.revertCycle(cycleKey: "2026-13", of: created.subscriptionID))
        XCTAssertNil(try sut.subscription.revertCycle(cycleKey: "", of: created.subscriptionID))

        let after = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(after.nextBillingDay, 20261215, "解析不出来就保持原样，不能把日期改成 0")
    }

    func testRevertCycleThrowsForUnknownSubscription() throws {
        let sut = try makeSUT()

        XCTAssertThrowsError(try sut.subscription.revertCycle(cycleKey: "2026-11", of: UUID())) { error in
            XCTAssertEqual(error as? SubscriptionError, .subscriptionNotFound)
        }
    }

    // MARK: - ⑧ D21 独立回归：回退重放 + 一串幂等命中之后，日期必须继续往前走

    /// 这条用例专门盯住 D21 那个 bug，**不依赖任何既有用例**。
    ///
    /// 触发条件三者同时成立才有意义：① B 分支把日期回退到很早的一期；
    /// ② 重放时先真的生成一笔；③ 紧随其后有一长串"幂等命中"被跳过。
    /// 旧实现只在"本轮一笔都没生成"时才补 advance，于是日期被**最后一条 action**
    /// 带到了下一期（3/22 那种半年前的位置）就停住了——之后每轮扫描都因为
    /// `nextBillingDay <= today` 反复空转，永远生成不出新账目，用户看到的
    /// "下次扣费日"停在过去。既有 26 条扫描用例全绿时这个 bug 依然存在，
    /// 因为它们都没有"生成 1 笔 + 后面一串跳过"这种组合。
    func testRevertedCycleFollowedByManyIdempotentHitsStillAdvancesNextBillingDay() throws {
        let sut = try makeSUT()
        // 锚定 22 号：最后一期刚好落在"明天"（11/22），这样第 ③ 步才有得测
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "每月 22 号", amount: 2500, firstBillingDay: 20260122),
            today: today
        )
        _ = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(try liveEntries(sut.writer).count, 10, "1/22 … 10/22 共 10 期")

        // 硬删很早的一期再回退：重放时会先补这一笔，然后连撞 8 次幂等
        let target = try XCTUnwrap(try liveEntries(sut.writer).first { $0.occurredDay == 20260222 })
        XCTAssertTrue(sut.ledger.hardDelete(id: target.id))
        _ = try sut.subscription.revertCycle(cycleKey: "2026-02", of: created.subscriptionID)

        let replay = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(replay.inserted, 1, "2/22 被重新生成")
        XCTAssertEqual(replay.skipped, 8, "3/22 … 10/22 共 8 期幂等命中")

        // ① 最终 nextBillingDay 必须严格晚于今天，且不能停在最后一个 action 的下一期
        let afterReplay = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(
            afterReplay.nextBillingDay, 20261122,
            "D21：重放后日期必须推到 11/22；旧实现会停在 3/22（半年前），从此再也生成不出账目"
        )
        XCTAssertGreaterThan(
            afterReplay.nextBillingDay, today.key,
            "下次扣费日必须晚于今天，否则订阅就卡死在过去了"
        )

        // ② 同一天再扫一次：账目总数不变，且没有任何新动作
        let countsBefore = try liveEntries(sut.writer).count
        let second = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.skipped, 0, "日期已经在今天之后，循环压根不该进")
        XCTAssertEqual(try liveEntries(sut.writer).count, countsBefore, "连扫两次账目数必须不变")

        // ③ 第二天到点：能正常生成新一期（证明订阅没被"冻住"）
        let tomorrow = today.adding(days: 1)
        let nextDay = sut.sweep.sweep(today: tomorrow, force: true)
        XCTAssertEqual(nextDay.inserted, 1, "11/22 到期，第二天扫描要生成这一期")
        XCTAssertNotNil(try liveEntries(sut.writer).first { $0.occurredDay == 20261122 })
        let afterTomorrow = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(afterTomorrow.nextBillingDay, 20261222, "下一期顺延到 12/22")
    }

    // MARK: - 工具

    private struct SUT {
        let container: ModelContainer
        let writer: LedgerWriter
        let ledger: LedgerService
        let subscription: SubscriptionService
        let sweep: SweepCoordinator
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let ledger = LedgerService(writer: writer)
        let subscription = SubscriptionService(writer: writer, ledger: ledger)
        let sweep = SweepCoordinator(writer: writer)
        return SUT(
            container: container,
            writer: writer,
            ledger: ledger,
            subscription: subscription,
            sweep: sweep
        )
    }

    /// 用户能看到的账目（软删的不算）。`allEntries()` 本身包含软删记录，
    /// 所以「硬删 vs 软删」的差别必须在这里显式过滤才看得出来。
    private func liveEntries(_ writer: LedgerWriter) throws -> [LedgerEntry] {
        try writer.fetch(QueryDescriptors.allEntries()).filter { $0.deletedAt == nil }
    }
}
