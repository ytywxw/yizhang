//
//  TrashFeatureTests.swift
//  一账Tests / Persistence
//
//  职责：在**真实 SwiftData 容器**上钉死「最近删除」的五条验收（V1.1 / T3 / 任务书 §5）。
//
//  为什么这些用例必须建真容器：
//  ① 保留期是按 `deletedDay` 的**整数谓词**筛的（`deletedDay < cutoff`），
//     换个日键口径就漏一条，纯 struct 上验不出来；
//  ② 恢复要回退订阅抑制表（`suppressedCycles` 是 `@Model` 上的逗号串），
//     只有落库之后重新 fetch 才能证明"真的写回去了"；
//  ③ "恢复后扫描不补第二笔"跨了三个组件（`TrashService.restore` → 幂等键 →
//     `SweepCoordinator.sweep`），任何一处断开都只有端到端跑一次才能发现。
//
//  覆盖清单（对应任务书 §5 的 ① ② ③ ④ ⑤ ⑧）：
//  ① 30 天边界：29 天前在列表（剩 1 天）、30 天整仍在保留期内、31 天前物理消失，
//     且列表里**没有任何"已过期"中间态**（不会出现负数剩余天数）；
//  ② 同一账目删两次：`deletion` 刷新成最新一次，剩余天数重新起算；
//  ③ 恢复 pending 账目后仍是 pending，并回到待确认列表（PRD 6.3-5）；
//  ④ 恢复订阅来源账目会 `unsuppress` 该 cycleKey，随后扫描不补出第二笔；
//  ⑤ `purgeAll` 之后 `count() == 0` 且分组为空；
//  ⑧ 源订阅已被删除时，`sourceRefID` 悬空保留（徽章要用），恢复不抛错。
//

import SwiftData
import XCTest
@testable import YiZhang

@MainActor
final class TrashFeatureTests: XCTestCase {

    /// 固定"今天"：2025-11-21。
    ///
    /// 必须同时注入 `LedgerService(today:)` 与 `sweep(today:)`：`validated` 第 ⑥ 步与
    /// 扫描窗口都用 `todayProvider()`，若它们读系统时钟，这组断言会随"今天"漂移。
    private let today = DateOnly(key: 20251121)

    // MARK: - ① 30 天边界

    func testRetentionWindowKeepsTwentyNineDaysAndPurgesThirtyOne() throws {
        let world = try makeWorld()
        let fresh = try world.insertEntry(amount: 1200, occurredDay: 20251101)
        let boundary = try world.insertEntry(amount: 2300, occurredDay: 20251102)
        let expired = try world.insertEntry(amount: 3400, occurredDay: 20251103)

        try world.markDeleted(fresh, atDay: today.adding(days: -29).key)
        try world.markDeleted(boundary, atDay: today.adding(days: -30).key)
        try world.markDeleted(expired, atDay: today.adding(days: -31).key)

        // 清理不在读路径上（读路径只做 `deletedDay > 0`），所以清理之前三条都在。
        // 这条断言同时说明"过期是靠挂载点清的，不是靠列表过滤"——两者语义不同：
        // 过滤只是藏起来（数据永久留库却不可达），清理才是 PRD 6.2 承诺的物理删除。
        XCTAssertEqual(try world.trash.count(), 3)

        XCTAssertEqual(
            try world.trash.purgeExpired(today: today),
            1,
            "只有 31 天前删除的那条超过保留期（30 天整属于最后一天，不能清）"
        )

        XCTAssertNil(try world.writer.entry(id: expired), "31 天前删除的必须物理消失")
        XCTAssertNotNil(try world.writer.entry(id: boundary), "正好 30 天整仍在保留期内")
        XCTAssertEqual(try world.trash.count(), 2)

        let items = try world.trash.items(today: today)
        XCTAssertEqual(Set(items.map(\.id)), [fresh, boundary])

        let freshItem = try XCTUnwrap(items.first { $0.id == fresh })
        XCTAssertEqual(freshItem.remainingDays, 1)
        XCTAssertTrue(freshItem.isExpiringSoon, "最后 1 天必须变色提示")
        XCTAssertEqual(freshItem.deletedDate, today.adding(days: -29))

        // 「无已过期中间态」的机器可验证形式：列表里不允许出现负数剩余天数。
        // 一旦有人把清理从挂载点搬到"渲染时过滤"，这里会立刻出现 -1 / -2。
        XCTAssertTrue(
            items.allSatisfy { $0.remainingDays >= 0 },
            "列表里不该有已过期的行，实际：\(items.map { "\($0.id):\($0.remainingDays)" })"
        )

        // 分组只按删除日倒序，29 天前那组在前
        XCTAssertEqual(
            try world.trash.groups(today: today).map(\.day),
            [today.adding(days: -29).key, today.adding(days: -30).key]
        )
    }

    // MARK: - ② 同一账目删两次

    func testDeletingTheSameEntryTwiceRefreshesTheDeletionMark() throws {
        let world = try makeWorld()
        let id = try world.insertEntry(amount: 2500, occurredDay: 20251101)

        try world.markDeleted(id, atDay: today.adding(days: -11).key)
        let first = try XCTUnwrap(try world.trash.items(today: today).first { $0.id == id })
        XCTAssertEqual(first.remainingDays, TrashService.retentionDays - 11)

        // 真实路径：用户在回收站里恢复了它，过几天又删了一次（或「不是这笔」之后再删）
        try world.trash.restore(id, at: today.adding(days: -6).date)
        XCTAssertEqual(try world.trash.count(), 0, "恢复后立刻离开回收站")

        try world.markDeleted(id, atDay: today.adding(days: -2).key)

        XCTAssertEqual(try world.trash.count(), 1, "同一账目删两次不能出现两行（它只是一条记录）")
        let second = try XCTUnwrap(try world.trash.items(today: today).first)
        XCTAssertEqual(second.id, id)
        XCTAssertEqual(
            second.deletedDay,
            today.adding(days: -2).key,
            "`deletion` 必须被刷新成最新一次，否则剩余天数会按旧的算（少给用户 9 天）"
        )
        XCTAssertEqual(second.deletedAt, today.adding(days: -2).date)
        XCTAssertEqual(
            second.remainingDays,
            TrashService.retentionDays - 2,
            "剩余天数必须按最新删除日重新起算"
        )
    }

    // MARK: - ③ 恢复 pending 后仍是 pending

    func testRestoringPendingEntryKeepsItPending() throws {
        let world = try makeWorld()
        let id = try world.makePendingEntry(amount: 2500)

        XCTAssertEqual(try world.ledger.pendingEntries().map(\.id), [id])

        try world.markDeleted(id, atDay: today.key)
        XCTAssertTrue(
            try world.ledger.pendingEntries().isEmpty,
            "进了回收站的账不属于「待确认」——它是待处理的删除，不是待处理的账"
        )

        try world.trash.restore(id, at: today.date)

        let restored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertEqual(
            restored.confirmRaw,
            EntryConfirmation.pending.raw,
            "PRD 6.3-5：恢复不能把待确认悄悄变成已确认（那等于替用户点了「这是对的」）"
        )
        XCTAssertTrue(restored.isPending)
        XCTAssertEqual(
            try world.ledger.pendingEntries().map(\.id),
            [id],
            "恢复后必须回到待确认列表，否则用户再也找不到这笔要核对的账"
        )
    }

    // MARK: - ④ 恢复订阅账目：unsuppress + 扫描不补第二笔

    func testRestoringSubscriptionEntryUnsuppressesCycleAndSweepDoesNotDuplicate() throws {
        let world = try makeWorld()
        let dueDay = today.adding(days: -3)
        let subscriptionID = try world.makeSubscription(firstBillingDay: dueDay.key)

        XCTAssertEqual(world.sweep.sweep(today: today, force: true).inserted, 1)
        let entry = try XCTUnwrap(try world.subscriptionEntries().first)
        let cycleKey = try XCTUnwrap(entry.sourceCycleKey)

        // 用户点「不是这笔」：软删 + 抑制该周期
        XCTAssertNotNil(try world.subscription.denyEntry(id: entry.id))
        let suppressed = try XCTUnwrap(try world.writer.subscription(id: subscriptionID))
        XCTAssertTrue(
            suppressed.suppressedCycleSet.contains(cycleKey),
            "前置条件：否定之后这一期确实进了抑制表（否则下面的 unsuppress 断言是空的）"
        )

        // 用户改主意，在回收站里把它恢复（PRD 6.3-1）
        try world.trash.restore(entry.id, at: Date())

        let afterRestore = try XCTUnwrap(try world.writer.subscription(id: subscriptionID))
        XCTAssertFalse(
            afterRestore.suppressedCycleSet.contains(cycleKey),
            "恢复必须回退抑制表：不回退的话这一期一旦被硬删就再也回不来"
        )
        XCTAssertFalse(try XCTUnwrap(try world.writer.entry(id: entry.id)).isDeleted)

        // 制造最坏局面：下次扣费日被退回该期（等价 T14 的 B 分支回退），
        // 于是扫描**确实会尝试**再生成这一期。此刻唯一能挡住重复的是幂等键，
        // 而恢复后的账目仍然占着它——这正是"恢复 ≠ 数据被抹掉重来"的机器可验证形式。
        try world.subscription.update(
            id: subscriptionID,
            changing: SubscriptionChanges(nextBillingDay: dueDay.key),
            today: today
        )

        let report = world.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 0, "恢复后的账目仍占着幂等键，扫描不能补出第二笔")
        XCTAssertEqual(try world.subscriptionEntries().count, 1, "同一期只允许一笔账")
    }

    // MARK: - ④b 恢复的金额精确性（PRD 6.4-2）

    /// 恢复必须**精确到分**地回到删除前，而不是只把 `deletedAt` 清掉。
    ///
    /// 既有恢复断言覆盖了 `deletedAt` / `deletedDay` / `confirmRaw` / `createdAt` /
    /// `sourceCycleUniqueKey` / `suppressedCycles`，**恰好漏掉 `amount` / `typeRaw` /
    /// `occurredDay`** —— 而决定"总额"的正是这三个。实现是对的
    /// （`LedgerEntry+Draft.apply(to:)` 逐字段写回），但测试抓不到漏写。
    ///
    /// 最后那条断言刻意走真实聚合 `StatisticsCalculator.totals`，而不是再手算一遍金额：
    /// PRD 6.4-2 的原话是「恢复为删除前数值（精确到分）」，用户能看见的就是这个合计。
    func testRestoreKeepsAmountTypeAndDaySoMonthlyTotalReturnsExactly() throws {
        let world = try makeWorld()
        let target = try world.insertEntry(amount: 1999, occurredDay: today.key, note: "午饭")
        _ = try world.insertEntry(amount: 2854, occurredDay: today.key, note: "超市")

        let before = try XCTUnwrap(try world.writer.entry(id: target))
        let beforeAmount = before.amount
        let beforeTypeRaw = before.typeRaw
        let beforeDay = before.occurredDay
        let beforeTotal = try world.monthExpenseCents(today)
        XCTAssertEqual(beforeTotal, 1999 + 2854, "前置条件：本月支出 = 两笔之和")

        try world.markDeleted(target, atDay: today.key)
        XCTAssertEqual(
            try world.monthExpenseCents(today), 2854,
            "前置条件：软删后合计立刻少掉这一笔（否则下面的恢复断言没有判别力）"
        )

        try world.trash.restore(target, at: today.date)

        let restored = try XCTUnwrap(try world.writer.entry(id: target))
        XCTAssertEqual(restored.amount, beforeAmount, "金额必须原样回来（分的精度不能借机被四舍五入）")
        XCTAssertEqual(
            restored.typeRaw, beforeTypeRaw,
            "类型必须原样回来（支出被写成收入会让合计的符号整个翻过来）"
        )
        XCTAssertEqual(
            restored.occurredDay, beforeDay,
            "发生日必须原样回来（换一个月就跑到别的月合计里，这个月凭空少了这笔）"
        )
        XCTAssertEqual(
            try world.monthExpenseCents(today), beforeTotal,
            "PRD 6.4-2：恢复为删除前数值（精确到分）——断言用户能看见的那个数"
        )
    }

    // MARK: - ⑤ purgeAll

    func testPurgeAllEmptiesTheTrash() throws {
        let world = try makeWorld()
        let first = try world.insertEntry(amount: 100, occurredDay: 20251101)
        let second = try world.insertEntry(amount: 200, occurredDay: 20251102)
        let live = try world.insertEntry(amount: 300, occurredDay: 20251103)
        try world.markDeleted(first, atDay: 20251105)
        try world.markDeleted(second, atDay: 20251106)

        XCTAssertEqual(try world.trash.purgeAll(), 2)
        XCTAssertEqual(try world.trash.count(), 0, "purgeAll 之后条数必须是 0")
        XCTAssertTrue(try world.trash.groups(today: today).isEmpty)
        XCTAssertTrue(try world.trash.items(today: today).isEmpty)
        XCTAssertNil(try world.writer.entry(id: first))
        XCTAssertNil(try world.writer.entry(id: second))
        XCTAssertNotNil(try world.writer.entry(id: live), "活账不能被顺手删掉")

        XCTAssertEqual(try world.trash.purgeAll(), 0, "幂等：空回收站再清一次返回 0，不抛错")
        XCTAssertNotNil(try world.writer.entry(id: live))
    }

    // MARK: - ⑧ 源订阅已删除

    func testRestoreWorksAndKeepsDanglingReferenceWhenSubscriptionIsGone() throws {
        let world = try makeWorld()
        let subscriptionID = try world.makeSubscription(firstBillingDay: today.adding(days: -3).key)
        _ = world.sweep.sweep(today: today, force: true)
        let entry = try XCTUnwrap(try world.subscriptionEntries().first)
        try world.markDeleted(entry.id, atDay: today.key)

        // 源订阅被删掉：行内徽章要能显示「订阅已删除」，而恢复不能因此失败（PRD 6.3-4）
        try world.subscription.delete(id: subscriptionID)
        XCTAssertNil(try world.writer.subscription(id: subscriptionID))

        let item = try XCTUnwrap(try world.trash.items(today: today).first)
        XCTAssertEqual(
            item.sourceRefID,
            subscriptionID,
            "悬空引用必须保留：徽章靠它判断「订阅已删除」，清了就退化成「无来源」"
        )
        XCTAssertEqual(item.source, .subscription)

        XCTAssertNoThrow(
            try world.trash.restore(entry.id, at: Date()),
            "订阅没了不该让「恢复」失败——救急页面弹错误只会让用户更慌"
        )

        let restored = try XCTUnwrap(try world.writer.entry(id: entry.id))
        XCTAssertFalse(restored.isDeleted)
        XCTAssertEqual(restored.sourceRefID, subscriptionID)
        XCTAssertEqual(try world.trash.count(), 0)
    }

    // MARK: - 夹具

    fileprivate struct World {
        let container: ModelContainer
        let writer: LedgerWriter
        let ledger: LedgerService
        let subscription: SubscriptionService
        let trash: TrashService
        let sweep: SweepCoordinator
        let categoryID: UUID
        let accountID: UUID
    }

    private func makeWorld() throws -> World {
        let container = try ModelContainerFactory.make(inMemory: true)
        try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let ledger = LedgerService(writer: writer, today: today)
        let subscription = SubscriptionService(writer: writer, ledger: ledger)
        let trash = TrashService(writer: writer, subscription: subscription)
        let sweep = SweepCoordinator(writer: writer)

        let categoryID = try XCTUnwrap(
            try writer.fetch(QueryDescriptors.categories(of: .expense)).first?.id,
            "种子数据必须带一个支出分类，否则账目无法通过校验"
        )
        let accountID = try XCTUnwrap(try writer.fetch(QueryDescriptors.accounts()).first?.id)

        return World(
            container: container,
            writer: writer,
            ledger: ledger,
            subscription: subscription,
            trash: trash,
            sweep: sweep,
            categoryID: categoryID,
            accountID: accountID
        )
    }
}

// MARK: - 夹具上的小工具

@MainActor
private extension TrashFeatureTests.World {

    /// 插一笔带分类与账户的账目（关系齐全，避免孤儿数据干扰断言语义）。
    @discardableResult
    func insertEntry(amount: Int64, occurredDay: Int32, note: String = "") throws -> UUID {
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: amount, occurredDay: occurredDay)
        draft.note = note
        draft.categoryID = categoryID
        draft.accountID = accountID
        let outcome = try writer.insert(draft)
        guard let id = outcome.entryID else {
            throw NSError(domain: "TrashFeatureTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "插入被幂等键拒绝：\(outcome)"
            ])
        }
        return id
    }

    /// 以"某个自然日"为删除时刻软删（`deletedDay` 由 `DateOnly` 反算，与线上一致）。
    func markDeleted(_ entryID: UUID, atDay day: Int32) throws {
        guard let entry = try writer.entry(id: entryID) else {
            throw NSError(domain: "TrashFeatureTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "找不到账目 \(entryID)"
            ])
        }
        try writer.markDeleted(entry, at: DateOnly(key: day).date)
    }

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
        // `nextBillingDay` 留 0 = 跟首次扣费日一致；`today` 注入固定日，
        // 否则 `backfillOption` 的判定会读系统时钟。
        let result = try subscription.create(draft, today: DateOnly(key: firstBillingDay))
        return result.subscriptionID
    }

    /// 造一笔**待确认**账目（订阅来源、不显式给 `confirmRaw`，由业务层判定）。
    func makePendingEntry(amount: Int64 = 2500, occurredDay: Int32? = nil) throws -> UUID {
        var draft = EntryDraft(
            typeRaw: EntryType.expense.raw,
            amount: amount,
            occurredDay: occurredDay ?? DateOnly(key: 20251121).key
        )
        draft.categoryID = categoryID
        draft.accountID = accountID
        draft.sourceRaw = EntrySource.subscription.raw
        // 幂等键必须每次唯一，否则第二笔会被静默跳过（`InsertOutcome.skippedDuplicate`）
        draft.sourceRefID = UUID()
        draft.sourceCycleKey = "cycle-\(UUID().uuidString.prefix(8))"
        draft.confirmRaw = nil
        let outcome = try ledger.create(draft)
        guard let id = outcome.entryID else {
            throw NSError(domain: "TrashFeatureTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "插入被幂等键拒绝：\(outcome)"
            ])
        }
        return id
    }

    /// 全部订阅来源账目（含软删，过滤逻辑由调用方按需做）。
    func subscriptionEntries() throws -> [LedgerEntry] {
        try writer.fetch(QueryDescriptors.entries(ofSource: .subscription))
    }

    /// 某月支出合计（分），走**真实生产聚合** `StatisticsCalculator.totals`。
    ///
    /// 刻意不在这里自己 `reduce` 求一遍：那样"测试算错了"和"实现漏写了"会互相掩盖。
    /// 走生产聚合时，这两者只要有一个不对，数字就对不上。
    func monthExpenseCents(_ today: DateOnly) throws -> Int64 {
        let entries = try writer.fetch(QueryDescriptors.monthEntries(today.monthKey))
        let lites = entries.map { entry in
            LedgerLite(
                id: entry.id,
                amount: entry.amount,
                typeRaw: entry.typeRaw,
                occurredDay: entry.occurredDay,
                categoryID: entry.category?.id,
                accountID: entry.account?.id,
                sourceRaw: entry.sourceRaw,
                confirmRaw: entry.confirmRaw,
                deletedAt: entry.deletedAt
            )
        }
        return StatisticsCalculator.totals(lites, range: .thisMonth, today: today).expense.cents
    }
}
