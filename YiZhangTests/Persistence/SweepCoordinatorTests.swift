//
//  SweepCoordinatorTests.swift
//  一账Tests / Persistence
//
//  覆盖 T11 的四条硬验收：
//  ① `nextBillingDay` 设为几个月前 → 每期一笔，`occurredAt` 是**各应扣日**（不是今天）；
//  ② **连跑 5 次，账目数不变**（幂等第 2 层：query-then-insert + 单写入口）；
//  ③ 24 笔上限命中即停、给订阅打标，下一次扫描从停下的地方继续；
//  ④ 不自动续费只产出提示；缺分类/缺账户时**不推进日期**（推进了等于永久漏账）。
//
//  这些用例需要真容器：要验证"账目 + 订阅日期在同一个 `save()` 里"必须真的落库。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SweepCoordinatorTests: XCTestCase {

    /// 固定"今天"：2026-11-21。
    private let today = DateOnly(key: 20261121)

    // MARK: - ① 补漏：日期落在各应扣日

    func testSweepCatchUpWritesOneEntryPerDueDay() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 3)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.advancedSubscriptionCount, 1)
        XCTAssertTrue(report.failedSubscriptionIDs.isEmpty)

        let entries = try sut.writer.fetch(QueryDescriptors.allEntries())
        XCTAssertEqual(entries.map(\.occurredDay).sorted(), [20260915, 20261015, 20261115])
        XCTAssertTrue(entries.allSatisfy { $0.occurredDay != today.key }, "occurredAt 必须是应扣日，不是今天")
        XCTAssertTrue(entries.allSatisfy { $0.type == .expense })
        XCTAssertTrue(entries.allSatisfy { $0.source == .subscription })
        XCTAssertTrue(entries.allSatisfy { $0.note == "订阅：视频会员" })
        XCTAssertTrue(
            entries.allSatisfy { $0.category?.id == PresetCatalog.subscriptionCategoryID },
            "分类继承订阅（默认「订阅服务」）"
        )
        XCTAssertTrue(entries.allSatisfy { $0.account != nil }, "账户必须落地")

        let subscription = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261215)
        XCTAssertEqual(subscription.lastSweptCycleKey, "2026-11")
    }

    // MARK: - ② 连跑 5 次账目数不变

    func testFiveConsecutiveSweepsKeepEntryCountStable() throws {
        let sut = try makeSUT()
        _ = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )

        var insertedPerRun: [Int] = []
        var counts: [Int] = []
        for _ in 0..<5 {
            let report = sut.sweep.sweep(today: today, force: true)
            insertedPerRun.append(report.inserted)
            counts.append(try sut.writer.count(QueryDescriptors.allEntries()))
        }

        XCTAssertEqual(
            insertedPerRun, [3, 0, 0, 0, 0],
            "只有第一次真正写账，之后每次都是幂等命中"
        )
        XCTAssertEqual(
            counts, [3, 3, 3, 3, 3],
            "连跑 5 次账目数必须不变"
        )
        XCTAssertEqual(Set(counts).count, 1)
    }

    func testSweepIsIdempotentAcrossDifferentTodayValues() throws {
        let sut = try makeSUT()
        _ = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )

        _ = sut.sweep.sweep(today: today, force: true)
        _ = sut.sweep.sweep(today: DateOnly(key: 20261122), force: true)

        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 3)
    }

    func testAutomaticSweepIsThrottledButForcedSweepIsNot() throws {
        let sut = try makeSUT()
        _ = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261115),
            today: today
        )

        let first = sut.sweep.sweep(today: today)          // 自动触发
        let second = sut.sweep.sweep(today: today)         // 60s 内 → 节流
        let forced = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(first.inserted, 1)
        XCTAssertTrue(second.isEmpty, "自动触发在 60s 窗口内应直接返回空结果")
        XCTAssertEqual(forced.inserted, 0, "强制扫描会真的执行，此时已无新账可写")
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 1)
    }

    // MARK: - ③ 24 笔上限

    func testTwentyFourCapStopsAndNextSweepContinues() throws {
        let sut = try makeSUT()
        let created = try sut.subscription.create(
            SubscriptionDraft(
                name: "每日订阅",
                amount: 100,
                cycleUnit: .day,
                cycleValue: 1,
                firstBillingDay: 20261023
            ),
            today: today
        )

        let first = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(first.inserted, 24)
        XCTAssertEqual(first.truncatedSubscriptionIDs, [created.subscriptionID])
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 24)

        var subscription = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261116, "停在未处理的那一期")

        let second = sut.sweep.sweep(today: today, force: true)
        XCTAssertEqual(second.inserted, 6, "剩下 11/16…11/21 六期")
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 30)

        subscription = try XCTUnwrap(try sut.subscription.subscription(id: created.subscriptionID))
        XCTAssertEqual(subscription.nextBillingDay, 20261122)
    }

    func testMultipleSubscriptionsEachGenerateTheirOwnEntries() throws {
        let sut = try makeSUT()
        _ = try sut.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20260915),
            today: today
        )
        _ = try sut.subscription.create(
            SubscriptionDraft(name: "云盘", amount: 1200, firstBillingDay: 20261018),
            today: today
        )

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 5, "3 笔 + 2 笔")
        XCTAssertEqual(report.advancedSubscriptionCount, 2)

        let entries = try sut.writer.fetch(QueryDescriptors.allEntries())
        let names = Set(entries.compactMap { $0.sourceRefID })
        XCTAssertEqual(names.count, 2, "两个订阅各自独立生成（E-6 不合并）")
    }

    // MARK: - ④ 不自动续费 / 缺分类

    func testAutoRenewFalseProducesNoticeWithoutEntry() throws {
        let sut = try makeSUT()
        _ = try sut.subscription.create(
            SubscriptionDraft(
                name: "健身房",
                amount: 19900,
                firstBillingDay: 20261118,
                autoRenew: false
            ),
            today: today
        )

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(report.notices.count, 1)
        XCTAssertEqual(report.notices.first?.name, "健身房")
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 0)

        let subscription = try XCTUnwrap(try sut.subscription.subscriptions().first)
        XCTAssertEqual(subscription.nextBillingDay, 20261118, "日期不推进，才能持续显示「待续费」")
    }

    func testMissingCategoryAndAccountIsReportedAndDateNotAdvanced() throws {
        let sut = try makeSUT()

        // 造一条"没有分类也没有账户"的脏订阅（正常 UI 不可能产生，但导入/云同步可能）
        let subscription = Subscription()
        subscription.id = UUID()
        subscription.name = "孤儿订阅"
        subscription.amount = 2500
        subscription.firstBillingDay = 20261118
        subscription.nextBillingDay = 20261118
        subscription.billingAnchorDay = 18
        subscription.status = .active
        subscription.autoRenew = true
        sut.writer.modelContext.insert(subscription)

        // 再把兜底用的分类和账户全部删掉
        for category in try sut.writer.fetch(FetchDescriptor<YiZhang.Category>()) {
            sut.writer.modelContext.delete(category)
        }
        for account in try sut.writer.fetch(FetchDescriptor<Account>()) {
            sut.writer.modelContext.delete(account)
        }
        try sut.writer.save()

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(report.failedSubscriptionIDs, [subscription.id])
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 0)
        XCTAssertEqual(
            subscription.nextBillingDay,
            20261118,
            "失败时绝不推进日期——推进了就等于永久跳过这一期"
        )
    }

    // MARK: - 空扫描

    func testSweepWithoutDueSubscriptionsDoesNothing() throws {
        let sut = try makeSUT()
        _ = try sut.subscription.create(
            SubscriptionDraft(name: "未来订阅", amount: 2500, firstBillingDay: 20261225),
            today: today
        )

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 0)
    }

    func testSweepOnEmptyDatabaseDoesNothing() throws {
        let sut = try makeSUT()

        let report = sut.sweep.sweep(today: today, force: true)

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try sut.writer.count(QueryDescriptors.allEntries()), 0)
    }

    // MARK: - 工具

    private struct SUT {
        let container: ModelContainer
        let writer: LedgerWriter
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
        return SUT(container: container, writer: writer, subscription: subscription, sweep: sweep)
    }
}
