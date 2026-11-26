//
//  PendingConfirmationTests.swift
//  一账Tests / Persistence
//
//  职责：在**真实 SwiftData 容器**上钉死「待确认」的六条链路（V1.1 F-SUB-13 / §5 收工标准）。
//
//  为什么这组测试不能只做 Domain 单测：
//  ① 规则本体（`EntryConfirmation.forSubscription`）已经被 `EntryConfirmationTests` 覆盖，
//     但那只能证明"函数算得对"。这条功能真正的风险在**写入路径**：规则算对了，
//     却没有人调用它（架构文档 §5-1 原来画的 `SweepCoordinator → validated` 就是断的，
//     `SweepCoordinator.swift` 实际是 `writer.insert(draft)` 直写）。所以这里的 ② 走
//     **完整扫描链路**（`SweepCoordinator.sweep` → `SweepPlanner` → `writer.insert`），
//     只要 `SweepAction.confirmRaw` 的透传链断在任一处，断言就会红。
//  ② 「否定」（`denyEntry`）跨了两个 Service + 三个副作用（软删 / 抑制周期 / 广播），
//     单看任何一层的返回值都发现不了"账目删了但周期没抑制"。
//
//  覆盖清单：
//  ② 冷启动补漏 60 天前 → 全 confirmed；3 天前 → pending（走真实扫描）；
//  ③ `validated` 第 ⑥ 步不覆盖显式传入的 confirmRaw；
//  ④ `confirm` 幂等、不改金额、非 pending 返回 false；
//  ⑤ `denyEntry` 后 `deletedAt != nil` 且 `suppressedCycles` 含该 cycleKey，再扫不生成该期；
//  ⑥ 订阅已删时 `denyEntry` 降级为纯软删、不抛错；
//  ⑦ `pendingSummary` / `confirmAll` / `pendingEntries` 的口径（含软删排除）。
//

import SwiftData
import XCTest
@testable import YiZhang

@MainActor
final class PendingConfirmationTests: XCTestCase {

    /// 固定"今天"：2026-03-15。
    ///
    /// 必须同时注入 `LedgerService(today:)`：`validated` 第 ⑥ 步用的是 `todayProvider()`，
    /// 若它读系统时钟，这组测试的断言就会随"今天"漂移（今天跑红、明天跑绿）。
    private let today = DateOnly(key: 20260315)

    // MARK: - 夹具

    fileprivate struct World {
        let container: ModelContainer
        let writer: LedgerWriter
        let ledger: LedgerService
        let subscription: SubscriptionService
        let sweep: SweepCoordinator
        let today: DateOnly
        let categoryID: UUID
        let accountID: UUID
    }

    private func makeWorld() throws -> World {
        let container = try ModelContainerFactory.make(inMemory: true)
        try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let ledger = LedgerService(writer: writer, today: today)
        let subscription = SubscriptionService(writer: writer, ledger: ledger)
        let sweep = SweepCoordinator(writer: writer)

        let categoryID = try XCTUnwrap(
            try writer.fetch(QueryDescriptors.categories(of: .expense)).first?.id,
            "种子数据必须带一个支出分类，否则所有账目都无法通过校验"
        )
        let accountID = try XCTUnwrap(
            try writer.fetch(QueryDescriptors.accounts()).first?.id
        )

        return World(
            container: container,
            writer: writer,
            ledger: ledger,
            subscription: subscription,
            sweep: sweep,
            today: today,
            categoryID: categoryID,
            accountID: accountID
        )
    }

    // MARK: - ② 扫描路径：冷启动补漏 vs 近期应扣日

    func testColdStartBackfillFarInThePastProducesOnlyConfirmedEntries() throws {
        let world = try makeWorld()
        // 用**季度**周期把补漏批次整体落在窗口之外：60 天前生成一笔后，
        // 下一期已经是 +31 天，补漏到此结束，于是这一批里没有任何一笔在 7 天窗口内。
        //
        // 为什么不用月度：月度从 60 天前补到今天，最后一期会落在"昨天"，
        // 按 PRD 2.2 它本来就**应该**是待确认（用户确实需要核对昨天那笔）。
        // 任务书 §5-② 写的"60 天前 → 全 confirmed"只在"批次整体在窗口外"时成立，
        // 这一点已在报告里向负责人说明。
        let sixtyDaysAgo = today.adding(days: -60)
        _ = try world.makeSubscription(firstBillingDay: sixtyDaysAgo.key, cycleUnit: .quarter)

        let report = world.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 1, "季度周期从 60 天前补漏只应补出 1 笔")

        let entries = try world.subscriptionEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.occurredDay, sixtyDaysAgo.key)
        XCTAssertTrue(entries.allSatisfy { $0.source == .subscription })

        // 核心断言：**一笔都不能是 pending**（架构 R7：判定基准是"今天"，不是"现在"）
        for entry in entries {
            XCTAssertEqual(
                entry.confirmation,
                .confirmed,
                "\(entry.occurredDay) 的账目距今天 60 天，不该有徽标"
            )
        }
        XCTAssertEqual(try world.ledger.pendingSummary().count, 0)
        XCTAssertTrue(try world.ledger.pendingEntries().isEmpty)
    }

    func testEntryDueThreeDaysAgoIsPending() throws {
        let world = try makeWorld()
        let threeDaysAgo = today.adding(days: -3)
        _ = try world.makeSubscription(amount: 2500, firstBillingDay: threeDaysAgo.key)

        let report = world.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 1)

        let entries = try world.subscriptionEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.occurredDay, threeDaysAgo.key)
        // 核心断言：这条链路（`SweepCoordinator` → `writer`，**不经过** `validated`）
        // 也必须带上 pending，否则 §0 描述的断链会静默复活。
        XCTAssertEqual(entries.first?.confirmation, .pending)

        let summary = try world.ledger.pendingSummary()
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.amount, Money(cents: 2500))
    }

    func testMixedWindowOnlyRecentEntriesArePending() throws {
        // 一个订阅、月度周期、从 60 天前开始补：只有进入 7 天窗口的那些才是 pending。
        // 这条用例防止"整批都标 pending"或"整批都不标"这类一刀切实现。
        let world = try makeWorld()
        let sixtyDaysAgo = today.adding(days: -60)
        _ = try world.makeSubscription(firstBillingDay: sixtyDaysAgo.key)

        _ = world.sweep.sweep(today: today, force: true)
        let entries = try world.subscriptionEntries()
        XCTAssertGreaterThan(entries.count, 1, "60 天 + 月度周期应当补出多笔")

        let windowStart = today.adding(days: -EntryConfirmation.pendingWindowDays).key
        for entry in entries {
            let expected: EntryConfirmation =
                entry.occurredDay >= windowStart ? .pending : .confirmed
            XCTAssertEqual(entry.confirmation, expected, "occurredDay=\(entry.occurredDay)")
        }
    }

    // MARK: - ③ `validated` 不覆盖显式传入的 `confirmRaw`

    func testValidatedKeepsExplicitConfirmedRaw() throws {
        let world = try makeWorld()

        // 应扣日 = 今天（不显式指定就会被判成 pending），显式要求 confirmed
        var draft = world.subscriptionDraft(occurredDay: today.key)
        draft.confirmRaw = EntryConfirmation.confirmed.raw

        let outcome = try world.ledger.create(draft)
        let id = try XCTUnwrap(outcome.entryID)

        XCTAssertEqual(try world.ledger.entry(id: id)?.confirmation, .confirmed)
    }

    func testValidatedKeepsExplicitPendingRaw() throws {
        let world = try makeWorld()

        // 应扣日 = 60 天前（不显式指定就会被判成 confirmed），显式要求 pending
        let sixtyDaysAgo = today.adding(days: -60)
        var draft = world.subscriptionDraft(occurredDay: sixtyDaysAgo.key)
        draft.confirmRaw = EntryConfirmation.pending.raw

        let outcome = try world.ledger.create(draft)
        let id = try XCTUnwrap(outcome.entryID)

        XCTAssertEqual(try world.ledger.entry(id: id)?.confirmation, .pending)
    }

    func testValidatedFillsPendingWhenRawIsNil() throws {
        // 对照组：同一个草稿，只是不传 confirmRaw → 由业务层判定成 pending。
        // 有了它，上面两条"显式值不被覆盖"才不是空断言（否则"永远不覆盖任何东西"也能过）。
        let world = try makeWorld()
        var draft = world.subscriptionDraft(occurredDay: today.key)
        draft.confirmRaw = nil

        let outcome = try world.ledger.create(draft)
        let id = try XCTUnwrap(outcome.entryID)

        XCTAssertEqual(try world.ledger.entry(id: id)?.confirmation, .pending)
    }

    func testManualEntryIsAlwaysConfirmed() throws {
        let world = try makeWorld()
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: 900, occurredDay: today.key)
        draft.categoryID = world.categoryID
        draft.accountID = world.accountID
        draft.sourceRaw = EntrySource.manual.raw
        draft.confirmRaw = nil

        let outcome = try world.ledger.create(draft)
        let id = try XCTUnwrap(outcome.entryID)

        XCTAssertEqual(try world.ledger.entry(id: id)?.confirmation, .confirmed)
        XCTAssertEqual(try world.ledger.pendingSummary().count, 0)
    }

    // MARK: - ④ `confirm` 幂等、不改金额

    func testConfirmIsIdempotentAndKeepsAmount() throws {
        let world = try makeWorld()
        let id = try world.makePendingEntry(amount: 2500)

        let before = try XCTUnwrap(try world.ledger.entry(id: id))
        XCTAssertEqual(before.confirmation, .pending)

        XCTAssertTrue(try world.ledger.confirm(id: id), "第一次确认必须返回 true")

        let after = try XCTUnwrap(try world.ledger.entry(id: id))
        XCTAssertEqual(after.confirmation, .confirmed)
        XCTAssertEqual(after.amount, 2500, "「这是对的」不是「以我说的为准」，金额绝不能变")
        XCTAssertEqual(after.occurredDay, before.occurredDay)
        XCTAssertEqual(after.note, before.note)

        // 幂等：第二次返回 false，不报错、不再写库
        XCTAssertFalse(try world.ledger.confirm(id: id))
        XCTAssertEqual(try world.ledger.pendingSummary().count, 0)
    }

    func testConfirmOfNonPendingEntryReturnsFalseWithoutThrowing() throws {
        let world = try makeWorld()
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: 900, occurredDay: today.key)
        draft.categoryID = world.categoryID
        draft.accountID = world.accountID
        draft.sourceRaw = EntrySource.manual.raw
        let id = try XCTUnwrap(try world.ledger.create(draft).entryID)

        XCTAssertFalse(try world.ledger.confirm(id: id))
        XCTAssertEqual(try world.ledger.entry(id: id)?.confirmation, .confirmed)
    }

    func testConfirmOfMissingEntryReturnsFalseWithoutThrowing() throws {
        let world = try makeWorld()
        XCTAssertFalse(try world.ledger.confirm(id: UUID()))
    }

    // MARK: - ⑤ `denyEntry`：软删 + 抑制周期 + 再扫不复活

    func testDenyEntrySoftDeletesAndSuppressesCycle() throws {
        let world = try makeWorld()
        let threeDaysAgo = today.adding(days: -3)
        let subscriptionID = try world.makeSubscription(firstBillingDay: threeDaysAgo.key)
        _ = world.sweep.sweep(today: today, force: true)

        let entry = try XCTUnwrap(try world.subscriptionEntries().first)
        let cycleKey = try XCTUnwrap(entry.sourceCycleKey)
        let nextBillingBefore = try XCTUnwrap(
            try world.writer.subscription(id: subscriptionID)
        ).nextBillingDay

        let token = try XCTUnwrap(try world.subscription.denyEntry(id: entry.id))
        XCTAssertEqual(token.entryID, entry.id)

        // ① 软删：两列同进同出（R1）
        let deleted = try XCTUnwrap(try world.writer.entry(id: entry.id))
        XCTAssertNotNil(deleted.deletedAt, "「不是这笔」必须让它从列表里消失")
        XCTAssertNotEqual(deleted.deletedDay, 0, "`deletedDay` 必须与 `deletedAt` 同进同出")
        XCTAssertEqual(deleted.deletedDay, Int32(DateOnly(deleted.deletedAt ?? Date()).key))

        // ② 抑制：周期键进 suppressedCycles
        let subscription = try XCTUnwrap(try world.writer.subscription(id: subscriptionID))
        XCTAssertTrue(
            subscription.suppressedCycleSet.contains(cycleKey),
            "周期键 \(cycleKey) 必须进抑制表，否则这条记录一被硬删，这一期就会复活"
        )

        // ③ 下次扣费日一律不回退（否定 ≠ 重新来过）
        XCTAssertEqual(
            subscription.nextBillingDay,
            nextBillingBefore,
            "否定不能让 nextBillingDay 回退——回退会让下一次扫描生成同一个周期，删一次长一次"
        )

        // ④ 幂等：再否定一次静默返回 nil
        XCTAssertNil(try world.subscription.denyEntry(id: entry.id))

        // ⑤ 列表口径：待确认里不该再有它
        XCTAssertTrue(try world.ledger.pendingEntries().isEmpty)
    }

    func testDenyEntryBlocksResurrectionEvenIfEntryIsHardDeleted() throws {
        // 这是抑制表存在的**唯一理由**（风险 R8）：软删记录仍占着幂等键，
        // 扫描本来就会跳过它；可一旦将来某条路径把它硬删了，只有抑制表能挡住复活。
        // 所以这里刻意制造"账目没了 + 日期退回该期"的最坏局面。
        let world = try makeWorld()
        let threeDaysAgo = today.adding(days: -3)
        let subscriptionID = try world.makeSubscription(firstBillingDay: threeDaysAgo.key)
        _ = world.sweep.sweep(today: today, force: true)

        let entry = try XCTUnwrap(try world.subscriptionEntries().first)
        let cycleKey = try XCTUnwrap(entry.sourceCycleKey)
        _ = try world.subscription.denyEntry(id: entry.id)

        // 硬删：幂等键不再被占用
        XCTAssertTrue(world.ledger.hardDelete(id: entry.id))
        // 日期退回该期（等价于 T14 的 B 分支回退）
        try world.subscription.update(
            id: subscriptionID,
            changing: SubscriptionChanges(nextBillingDay: threeDaysAgo.key),
            today: today
        )

        let report = world.sweep.sweep(today: today, force: true)
        XCTAssertEqual(
            report.inserted,
            0,
            "该周期已被抑制，不能再生成账目（周期键 \(cycleKey)）"
        )
        XCTAssertTrue(try world.subscriptionEntries().isEmpty)
    }

    // MARK: - ⑥ 订阅已删：降级为纯软删，不抛错

    func testDenyEntryDegradesToSoftDeleteWhenSubscriptionIsGone() throws {
        let world = try makeWorld()
        let threeDaysAgo = today.adding(days: -3)
        let subscriptionID = try world.makeSubscription(firstBillingDay: threeDaysAgo.key)
        _ = world.sweep.sweep(today: today, force: true)

        let entry = try XCTUnwrap(try world.subscriptionEntries().first)
        try world.subscription.delete(id: subscriptionID)
        XCTAssertNil(try world.writer.subscription(id: subscriptionID))

        // 不抛错是关键：用户说"不是这笔"，账目必须照样消失，
        // 不能因为订阅记录已经不在就弹一句"找不到订阅"。
        let token = try XCTUnwrap(try world.subscription.denyEntry(id: entry.id))
        XCTAssertEqual(token.entryID, entry.id)

        let deleted = try XCTUnwrap(try world.writer.entry(id: entry.id))
        XCTAssertNotNil(deleted.deletedAt)
        XCTAssertNotEqual(deleted.deletedDay, 0)
        // 悬空引用保留：历史账目仍能显示「订阅已删除」
        XCTAssertEqual(deleted.sourceRefID, subscriptionID)
    }

    // MARK: - ⑦ 汇总与批量确认的口径

    func testPendingSummaryIgnoresDeletedEntries() throws {
        let world = try makeWorld()
        let first = try world.makePendingEntry(amount: 1000)
        let second = try world.makePendingEntry(amount: 2000)

        XCTAssertEqual(try world.ledger.pendingSummary().count, 2)
        XCTAssertEqual(try world.ledger.pendingSummary().amount, Money(cents: 3000))

        _ = try world.subscription.denyEntry(id: first)

        let summary = try world.ledger.pendingSummary()
        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.amount, Money(cents: 2000))
        XCTAssertEqual(try world.ledger.pendingEntries().map(\.id), [second])
    }

    func testPendingEntriesAreSortedByDueDayDescending() throws {
        let world = try makeWorld()
        _ = try world.makePendingEntry(amount: 1000, occurredDay: today.adding(days: -7).key)
        _ = try world.makePendingEntry(amount: 2000, occurredDay: today.key)
        _ = try world.makePendingEntry(amount: 3000, occurredDay: today.adding(days: -3).key)

        let days = try world.ledger.pendingEntries().map(\.occurredDay)
        XCTAssertEqual(days, days.sorted(by: >), "核对页最近的排前面")
        XCTAssertEqual(days.count, 3)
    }

    func testConfirmAllConfirmsEverythingInOneGo() throws {
        let world = try makeWorld()
        _ = try world.makePendingEntry(amount: 1000, occurredDay: today.adding(days: -7).key)
        _ = try world.makePendingEntry(amount: 2000, occurredDay: today.key)
        _ = try world.makePendingEntry(amount: 3000, occurredDay: today.adding(days: -3).key)

        var commitCount = 0
        world.ledger.onDidCommit = { commitCount += 1 }

        XCTAssertEqual(try world.ledger.confirmAll(), 3)
        XCTAssertEqual(commitCount, 1, "批量确认只广播一次：逐笔广播会让列表闪烁十几下")
        XCTAssertEqual(try world.ledger.pendingSummary().count, 0)

        // 幂等：没有待确认时返回 0，不广播
        XCTAssertEqual(try world.ledger.confirmAll(), 0)
        XCTAssertEqual(commitCount, 1)
    }
}

// MARK: - 夹具上的小工具

/// 标 `@MainActor`：`LedgerWriter` / 两个 Service 都是 MainActor 隔离的，
/// 扩展方法若不标就会以 nonisolated 身份出现，从同步上下文里调不到它们。
@MainActor
private extension PendingConfirmationTests.World {

    /// 造一个订阅（默认月度、自动续费、金额 2500）。
    @discardableResult
    func makeSubscription(
        name: String = "视频会员",
        amount: Int64 = 2500,
        firstBillingDay: Int32,
        cycleUnit: CycleUnit = .month
    ) throws -> UUID {
        var draft = SubscriptionDraft()
        draft.name = name
        draft.amount = amount
        draft.cycleUnit = cycleUnit
        draft.cycleValue = 1
        draft.firstBillingDay = firstBillingDay
        draft.categoryID = categoryID
        draft.accountID = accountID
        // `nextBillingDay` 留 0 = 跟首次扣费日一致；`today` 也用固定日，
        // 否则 `backfillOption` 的判定会读系统时钟。
        let result = try subscription.create(
            draft,
            today: DateOnly(key: firstBillingDay)
        )
        return result.subscriptionID
    }

    /// 订阅来源的账目草稿（关系齐全、幂等键由 `validated` 补齐）。
    func subscriptionDraft(occurredDay: Int32, amount: Int64 = 2500) -> EntryDraft {
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: amount, occurredDay: occurredDay)
        draft.categoryID = categoryID
        draft.accountID = accountID
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = UUID()
        draft.sourceCycleKey = "2026-03"
        return draft
    }

    /// 造一笔**待确认**账目（默认应扣日 = 今天，订阅来源，不显式给 confirmRaw）。
    func makePendingEntry(amount: Int64 = 2500, occurredDay: Int32? = nil) throws -> UUID {
        var draft = subscriptionDraft(occurredDay: occurredDay ?? today.key, amount: amount)
        draft.confirmRaw = nil
        // 幂等键必须每次唯一，否则第二笔会被 silently 跳过（`InsertOutcome.skippedDuplicate`）
        draft.sourceRefID = UUID()
        draft.sourceCycleKey = "cycle-\(UUID().uuidString.prefix(8))"
        let outcome = try ledger.create(draft)
        guard let id = outcome.entryID else {
            throw NSError(domain: "PendingConfirmationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "插入被幂等键拒绝：\(outcome)"
            ])
        }
        return id
    }

    /// 全部订阅来源账目（含软删，排除逻辑由调用方按需做）。
    func subscriptionEntries() throws -> [LedgerEntry] {
        try writer.fetch(QueryDescriptors.entries(ofSource: .subscription))
    }
}
