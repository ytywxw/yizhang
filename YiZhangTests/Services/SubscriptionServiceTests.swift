//
//  SubscriptionServiceTests.swift
//  一账Tests / Services
//
//  覆盖 T10 的五条验收：
//  ① PRD 附录 A.2 的五条状态迁移（含非法迁移必须抛错）；
//  ② 暂停期间不生成、恢复顺延且**不补暂停期账目**（E-4）；
//  ③ 取消后 `nextBillingDay = 0` 且历史账目保留（E-3）；
//  ④ 试用期对齐 + 金额为 0 允许保存（E-1 / E-9）；
//  ⑤ 补录默认 0 期、只补最近 12 期、用户显式指定才写账（E-5）。
//
//  这些用例都要真容器：状态机写在模型上、锚定日要真的落库才验证得动。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SubscriptionServiceTests: XCTestCase {

    /// 固定"今天"：2026-11-21。
    private let today = DateOnly(key: 20261121)

    // MARK: - 新建

    func testCreateWithPastFirstBillingOffersBackfillButWritesNothing() throws {
        let sut = try makeSUT()

        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260815),
            today: today
        )

        XCTAssertEqual(result.nextBillingDay, 20260815)
        XCTAssertEqual(try entryCount(sut.writer), 0, "补录默认不补：创建时一笔账都不写")

        let option = try XCTUnwrap(result.backfill)
        XCTAssertTrue(option.isOffered)
        XCTAssertEqual(option.availableCycles, 4, "8/15、9/15、10/15、11/15 四期已过")
        XCTAssertEqual(BackfillOption.defaultCycles, 0, "E-5：默认不补")
        XCTAssertEqual(option.latestDay, DateOnly(key: 20261115))

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.billingAnchorDay, 15, "锚定日 = 首次扣费日的日号")
        XCTAssertEqual(subscription.firstBillingDay, 20260815)
        XCTAssertEqual(subscription.status, .active)
        XCTAssertNotNil(subscription.category?.id)
        XCTAssertNotNil(subscription.account?.id)
    }

    func testCreateWithTrialAlignsBillingToTrialEndAndOffersNoBackfill() throws {
        let sut = try makeSUT()

        let result = try sut.service.create(
            SubscriptionDraft(
                name: "云盘",
                amount: 12000,
                firstBillingDay: 20260801,
                trialEndDay: 20261205
            ),
            today: today
        )

        XCTAssertEqual(result.nextBillingDay, 20261205, "E-1：nextBillingDate 应等于试用结束日")
        XCTAssertNil(result.backfill, "试用期内没有可补的历史账目")

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.trialEndDay, 20261205)
        XCTAssertEqual(subscription.firstBillingDay, 20261205)
        XCTAssertEqual(subscription.billingAnchorDay, 5)
    }

    func testCreateAllowsZeroAmount() throws {
        let sut = try makeSUT()

        let result = try sut.service.create(
            SubscriptionDraft(name: "免费试用", amount: 0, firstBillingDay: 20260815),
            today: today
        )

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.amount, 0, "E-9：金额为 0 允许保存")
        XCTAssertNil(result.backfill, "没有金额就没有账目可补")
    }

    func testCreateRejectsEmptyNameAndOverlongName() throws {
        let sut = try makeSUT()

        XCTAssertThrowsError(try sut.service.create(SubscriptionDraft(name: "   "), today: today)) { error in
            XCTAssertEqual(error as? SubscriptionError, .nameEmpty)
        }
        let longName = String(repeating: "长", count: SubscriptionService.nameLimit + 1)
        XCTAssertThrowsError(try sut.service.create(SubscriptionDraft(name: longName), today: today)) { error in
            XCTAssertEqual(error as? SubscriptionError, .nameTooLong)
        }
    }

    func testCreateRejectsOutOfRangeCycleValue() throws {
        let sut = try makeSUT()

        XCTAssertThrowsError(
            try sut.service.create(SubscriptionDraft(name: "订阅", cycleValue: 0), today: today)
        ) { error in
            XCTAssertEqual(error as? SubscriptionError, .invalidCycleValue)
        }
    }

    // MARK: - 状态机 A.2

    func testPauseKeepsNextBillingDay() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261125),
            today: today
        )

        try sut.service.pause(id: result.subscriptionID)

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.status, .paused)
        XCTAssertEqual(subscription.nextBillingDay, 20261125, "A.2：暂停时 nextBillingDate 保留")
    }

    func testResumeAdvancesPastTodayWithoutGeneratingBackfill() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260815),
            today: today
        )
        try sut.service.pause(id: result.subscriptionID)

        try sut.service.resume(id: result.subscriptionID, today: today)

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.status, .active)
        XCTAssertEqual(subscription.nextBillingDay, 20261215, "恢复时顺延到「今天之后第一个周期日」")
        XCTAssertEqual(try entryCount(sut.writer), 0, "E-4：不为暂停期补账（暂停期间本来就没花钱）")
    }

    func testCancelClearsNextBillingDayAndKeepsHistoryEntries() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(
                name: "健身房",
                amount: 19900,
                firstBillingDay: 20261118,
                autoRenew: false
            ),
            today: today
        )

        let renewal = try XCTUnwrap(try sut.service.markRenewed(id: result.subscriptionID, today: today))
        XCTAssertTrue(renewal.didGenerate)
        XCTAssertEqual(try entryCount(sut.writer), 1)

        try sut.service.cancel(id: result.subscriptionID)

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.status, .cancelled)
        XCTAssertEqual(subscription.nextBillingDay, 0, "E-3：取消后置空下次扣费日")
        XCTAssertEqual(try entryCount(sut.writer), 1, "E-3：历史账目全部保留")
        XCTAssertTrue(try entries(sut.writer).allSatisfy { $0.sourceRefID == result.subscriptionID })
    }

    func testReactivateResetsAnchorDayFromNewDate() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261118),
            today: today
        )
        try sut.service.cancel(id: result.subscriptionID)

        try sut.service.reactivate(id: result.subscriptionID, nextBillingDay: 20261231, today: today)

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.status, .active)
        XCTAssertEqual(subscription.nextBillingDay, 20261231)
        XCTAssertEqual(subscription.billingAnchorDay, 31, "重设下次扣费日 = 一次校正，锚定日跟着重置")
    }

    func testReactivateWithoutDateUsesOneCycleAfterToday() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261118),
            today: today
        )
        try sut.service.cancel(id: result.subscriptionID)

        try sut.service.reactivate(id: result.subscriptionID, today: today)

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261218, "默认今天 + 1 个周期（锚定日 18）")
        XCTAssertEqual(subscription.billingAnchorDay, 18)
    }

    func testIllegalTransitionsThrow() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261125),
            today: today
        )

        XCTAssertThrowsError(try sut.service.resume(id: result.subscriptionID, today: today)) { error in
            XCTAssertEqual(
                error as? SubscriptionError,
                .transitionNotAllowed(from: .active)
            )
        }

        try sut.service.pause(id: result.subscriptionID)
        XCTAssertThrowsError(try sut.service.pause(id: result.subscriptionID)) { error in
            XCTAssertEqual(
                error as? SubscriptionError,
                .transitionNotAllowed(from: .paused)
            )
        }

        try sut.service.cancel(id: result.subscriptionID)
        XCTAssertThrowsError(try sut.service.pause(id: result.subscriptionID)) { error in
            XCTAssertEqual(
                error as? SubscriptionError,
                .transitionNotAllowed(from: .cancelled)
            )
        }
    }

    // MARK: - 已续费（R-SUB-6）

    func testMarkRenewedWritesOneEntryAndAdvancesOneCycle() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(
                name: "健身房",
                amount: 19900,
                firstBillingDay: 20261118,
                autoRenew: false
            ),
            today: today
        )

        let renewal = try XCTUnwrap(try sut.service.markRenewed(id: result.subscriptionID, today: today))

        XCTAssertEqual(renewal.nextBillingDay, 20261218)
        XCTAssertEqual(try entryCount(sut.writer), 1)
        let entry = try XCTUnwrap(try entries(sut.writer).first)
        XCTAssertEqual(entry.occurredDay, 20261118, "账目日期用应扣日")
        XCTAssertEqual(entry.amount, 19900)
        XCTAssertEqual(entry.note, "订阅：健身房")
        XCTAssertEqual(entry.source, .subscription)
        XCTAssertEqual(entry.sourceCycleKey, "2026-11")
        XCTAssertEqual(
            entry.sourceCycleUniqueKey,
            SubscriptionSnapshot.makeUniqueKey(subscriptionID: result.subscriptionID, cycleKey: "2026-11")
        )
    }

    func testMarkRenewedIgnoredWhenAutoRenewIsOn() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261118),
            today: today
        )

        XCTAssertNil(try sut.service.markRenewed(id: result.subscriptionID, today: today))
        XCTAssertEqual(try entryCount(sut.writer), 0)
    }

    func testMarkRenewedIgnoredBeforeDueDate() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(
                name: "健身房",
                amount: 19900,
                firstBillingDay: 20261218,
                autoRenew: false
            ),
            today: today
        )

        XCTAssertNil(try sut.service.markRenewed(id: result.subscriptionID, today: today))
        XCTAssertEqual(try entryCount(sut.writer), 0)
    }

    // MARK: - 补录（E-5）

    func testBackfillGeneratesOnlyRequestedMostRecentCycles() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260815),
            today: today
        )

        let inserted = try sut.service.backfill(
            subscriptionID: result.subscriptionID,
            cycles: 2,
            today: today
        )

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(
            try entries(sut.writer).map(\.occurredDay).sorted(),
            [20261015, 20261115],
            "只补最近 N 期：用户看到的是「最近」，从最早一期补会让人觉得没生效"
        )

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261215, "补录后日期推进到今天之后")
        XCTAssertEqual(try entryCount(sut.writer), 2)
    }

    func testBackfillZeroCyclesWritesNothing() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260815),
            today: today
        )

        XCTAssertEqual(
            try sut.service.backfill(subscriptionID: result.subscriptionID, cycles: 0, today: today),
            0
        )
        XCTAssertEqual(try entryCount(sut.writer), 0)
    }

    func testBackfillIsCappedAtTwelveCycles() throws {
        let sut = try makeSUT()
        // 两年每月一期 → 可补期数会被封顶到 12
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20241215),
            today: today
        )

        let option = try XCTUnwrap(result.backfill)
        XCTAssertEqual(option.availableCycles, BackfillOption.maximumCycles)

        let inserted = try sut.service.backfill(
            subscriptionID: result.subscriptionID,
            cycles: 99,
            today: today
        )
        XCTAssertEqual(inserted, BackfillOption.maximumCycles)
    }

    func testBackfillIsIdempotent() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260815),
            today: today
        )

        _ = try sut.service.backfill(subscriptionID: result.subscriptionID, cycles: 4, today: today)
        let second = try sut.service.backfill(subscriptionID: result.subscriptionID, cycles: 4, today: today)

        XCTAssertEqual(second, 0, "同一批周期第二次补录必须全部被幂等挡住")
        XCTAssertEqual(try entryCount(sut.writer), 4)
    }

    // MARK: - 编辑（E-2 / E-10）

    func testUpdateAmountAndCorrectionResetsAnchor() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261125),
            today: today
        )

        let option = try sut.service.update(
            id: result.subscriptionID,
            changing: SubscriptionChanges(
                amount: 3000,
                firstBillingDay: 20261101,
                nextBillingDay: 20261120
            ),
            today: today
        )

        let subscription = try XCTUnwrap(try sut.service.subscription(id: result.subscriptionID))
        XCTAssertEqual(subscription.amount, 3000, "E-2：改金额只影响之后")
        XCTAssertEqual(subscription.nextBillingDay, 20261120)
        XCTAssertEqual(subscription.billingAnchorDay, 20, "E-10：手改日期视为校正，锚定日重置")
        XCTAssertEqual(option?.availableCycles, 1, "校正到 11/20 后，只有这一期是欠账")

        XCTAssertEqual(try entryCount(sut.writer), 0, "编辑本身不写账")
    }

    // MARK: - 删除（E-11）

    func testDeleteRemovesRecordButKeepsHistory() throws {
        let sut = try makeSUT()
        let result = try sut.service.create(
            SubscriptionDraft(
                name: "健身房",
                amount: 19900,
                firstBillingDay: 20261118,
                autoRenew: false
            ),
            today: today
        )
        _ = try sut.service.markRenewed(id: result.subscriptionID, today: today)

        try sut.service.delete(id: result.subscriptionID)

        XCTAssertTrue(try sut.service.subscriptions().isEmpty)
        XCTAssertEqual(try entryCount(sut.writer), 1, "E-11：删订阅不删历史账目")
        XCTAssertEqual(
            try entries(sut.writer).first?.sourceRefID,
            Optional(result.subscriptionID),
            "历史账目保留来源 id（UI 显示「订阅已删除」）"
        )
    }

    // MARK: - 工具

    private struct SUT {
        let container: ModelContainer
        let writer: LedgerWriter
        let ledger: LedgerService
        let service: SubscriptionService
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let ledger = LedgerService(writer: writer)
        let service = SubscriptionService(writer: writer, ledger: ledger)
        return SUT(container: container, writer: writer, ledger: ledger, service: service)
    }

    private func entries(_ writer: LedgerWriter) throws -> [LedgerEntry] {
        try writer.fetch(QueryDescriptors.allEntries())
    }

    private func entryCount(_ writer: LedgerWriter) throws -> Int {
        try writer.count(QueryDescriptors.allEntries())
    }
}
