//
//  TrashViewModelTests.swift
//  一账Tests / Features
//
//  职责：钉死「最近删除」页 ViewModel 的三件"只能在这一层做对"的事（V1.1 / T3 §1）。
//
//  ① **分组标题按自然日算**：`今天` / `昨天` / `11月18日`。
//     这一条必须在 VM 层验：它很容易被写成 `Calendar.isDateInToday` 或
//     `DateFormatter("M月d日")`，而后者会带上用户时区/地区设置，
//     跨时区、跨夏令时都会出现"明明是昨天删的，显示成前天"。
//     `TrashViewModel.title(forDay:today:)` 是纯整数比较，这里用固定 `today` 断言三种形态。
//  ② **"源对象已删除"只影响徽章**：判据是两个条件（`sourceRefID` 存在 + 源对象查不到），
//     少判一个会把"缺 id 的历史账目"或"手动记账"误标成已删除。
//  ③ **写入后立刻重读**：恢复/彻底删除之后列表要马上变（`reload()` 在动作里调），
//     否则用户点了「恢复」却还看到那一条，只能反复点。
//
//  为什么用 `AppEnvironment` 而不是裸 writer：VM 的依赖就是这个容器
//  （`attach(_:)` 取 `readContext` / `trash`），用真容器才能连"只读上下文能不能读到
//  写上下文刚提交的软删标记"一起验掉。
//

import SwiftData
import XCTest
@testable import YiZhang

@MainActor
final class TrashViewModelTests: XCTestCase {

    /// 固定"今天"：2025-11-21（注入 `todayProvider`，断言不随跑测试的那天漂移）。
    private let today = DateOnly(key: 20251121)

    // MARK: - ① 分组标题

    func testGroupTitlesAreTodayYesterdayAndDisplayDate() throws {
        let environment = try makeEnvironment()
        let todayID = try insertEntry(environment, amount: 1000, occurredDay: 20251120)
        let yesterdayID = try insertEntry(environment, amount: 2000, occurredDay: 20251119)
        let olderID = try insertEntry(environment, amount: 3000, occurredDay: 20251101)

        try markDeleted(environment, todayID, atDay: today.key)
        try markDeleted(environment, yesterdayID, atDay: today.adding(days: -1).key)
        try markDeleted(environment, olderID, atDay: today.adding(days: -5).key)

        let viewModel = makeViewModel()
        viewModel.attach(environment)

        XCTAssertTrue(viewModel.isLoaded)
        XCTAssertEqual(viewModel.count, 3)
        XCTAssertEqual(
            viewModel.groups.map(\.title),
            ["今天", "昨天", today.adding(days: -5).displayString],
            "组标题只认自然日差：今天 / 昨天 / M月d日"
        )
        // 顺序来自 `TrashService`，VM 一律不再排（两个排序点迟早分叉）
        XCTAssertEqual(
            viewModel.groups.map(\.day),
            [today.key, today.adding(days: -1).key, today.adding(days: -5).key]
        )
        XCTAssertEqual(viewModel.groups.map(\.count), [1, 1, 1])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testTitleFallsBackToUnknownDateForInvalidKey() {
        // 日键非法时不能崩、也不能显示成"今天"（那会让用户以为刚删的）
        XCTAssertEqual(TrashViewModel.title(forDay: 0, today: today), "未知日期")
    }

    // MARK: - ② 源对象已删除只影响徽章

    func testSourceBadgeTurnsIntoDeletedHintWhenSubscriptionIsGone() throws {
        let environment = try makeEnvironment()
        let subscriptionID = try makeSubscription(environment, firstBillingDay: today.adding(days: -3).key)
        XCTAssertEqual(environment.sweep.sweep(today: today, force: true).inserted, 1)

        let entry = try XCTUnwrap(
            environment.writer.fetch(QueryDescriptors.entries(ofSource: .subscription)).first
        )
        try markDeleted(environment, entry.id, atDay: today.key)

        let viewModel = makeViewModel()
        viewModel.attach(environment)
        let liveRow = try XCTUnwrap(viewModel.groups.first?.rows.first)
        XCTAssertFalse(liveRow.isSourceDeleted, "订阅还在时不该说「订阅已删除」")
        XCTAssertEqual(liveRow.sourceBadgeText, EntrySource.subscription.displayName)
        XCTAssertTrue(liveRow.item.isPending, "3 天前的订阅账目本来就该是待确认（PRD 2.2）")

        // 订阅被删掉：徽章变成「订阅已删除」，但这一行还在（账目是独立存在的）
        try environment.subscription.delete(id: subscriptionID)
        viewModel.reload()

        let orphanRow = try XCTUnwrap(viewModel.groups.first?.rows.first)
        XCTAssertTrue(orphanRow.isSourceDeleted)
        XCTAssertEqual(orphanRow.sourceBadgeText, "订阅已删除")
        XCTAssertEqual(viewModel.count, 1, "源对象没了不影响这一行本身")
    }

    func testManualEntryNeverGetsSourceDeletedBadge() throws {
        let environment = try makeEnvironment()
        let id = try insertEntry(environment, amount: 1200, occurredDay: 20251101)
        try markDeleted(environment, id, atDay: today.key)

        let viewModel = makeViewModel()
        viewModel.attach(environment)

        let row = try XCTUnwrap(viewModel.groups.first?.rows.first)
        XCTAssertFalse(row.isSourceDeleted, "手动记账没有源对象，永远不该被判成「已删除」")
        XCTAssertEqual(row.sourceBadgeText, "", "手动记账不显示来源徽章")
    }

    // MARK: - ③ 写入后立刻重读

    func testRestoreRemovesRowImmediately() throws {
        let environment = try makeEnvironment()
        let id = try insertEntry(environment, amount: 2500, occurredDay: 20251101, note: "午饭")
        try markDeleted(environment, id, atDay: today.key)

        let viewModel = makeViewModel()
        viewModel.attach(environment)
        XCTAssertEqual(viewModel.count, 1)

        try viewModel.restore(id: id)

        XCTAssertEqual(viewModel.count, 0, "恢复之后列表要立刻变空，否则用户会反复点")
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertNotNil(try environment.writer.entry(id: id))
    }

    func testPurgeAllEmptiesGroupsAndCount() throws {
        let environment = try makeEnvironment()
        let first = try insertEntry(environment, amount: 1000, occurredDay: 20251101)
        let second = try insertEntry(environment, amount: 2000, occurredDay: 20251102)
        try markDeleted(environment, first, atDay: today.key)
        try markDeleted(environment, second, atDay: today.adding(days: -1).key)

        let viewModel = makeViewModel()
        viewModel.attach(environment)
        XCTAssertEqual(viewModel.count, 2)

        XCTAssertEqual(try viewModel.purgeAll(), 2)
        XCTAssertEqual(viewModel.count, 0)
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertNil(try environment.writer.entry(id: first))
        XCTAssertNil(try environment.writer.entry(id: second))
        XCTAssertEqual(try viewModel.purgeAll(), 0, "空回收站再清一次是 0，不是报错")
    }

    func testPurgeSingleRowRemovesOnlyThatRow() throws {
        let environment = try makeEnvironment()
        let keep = try insertEntry(environment, amount: 1000, occurredDay: 20251101)
        let drop = try insertEntry(environment, amount: 2000, occurredDay: 20251102)
        try markDeleted(environment, keep, atDay: today.key)
        try markDeleted(environment, drop, atDay: today.key)

        let viewModel = makeViewModel()
        viewModel.attach(environment)

        try viewModel.purge(id: drop)

        XCTAssertEqual(viewModel.count, 1)
        XCTAssertEqual(viewModel.groups.first?.rows.first?.id, keep)
        XCTAssertNil(try environment.writer.entry(id: drop))
    }

    // MARK: - 夹具

    private func makeEnvironment() throws -> AppEnvironment {
        try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
    }

    private func makeViewModel() -> TrashViewModel {
        // 用局部常量捕获，而不是把 `self` 带进闭包：VM 活得比单个测试方法长，
        // 捕获 XCTestCase 会让它一直拽着整个测试实例。
        let fixedToday = today
        return TrashViewModel(todayProvider: { fixedToday })
    }

    @discardableResult
    private func insertEntry(
        _ environment: AppEnvironment,
        amount: Int64,
        occurredDay: Int32,
        note: String = ""
    ) throws -> UUID {
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: amount, occurredDay: occurredDay)
        draft.note = note
        draft.categoryID = try environment.writer
            .fetch(QueryDescriptors.categories(of: .expense)).first?.id
        draft.accountID = try environment.writer.fetch(QueryDescriptors.accounts()).first?.id
        let outcome = try environment.writer.insert(draft)
        return try XCTUnwrap(outcome.entryID)
    }

    private func markDeleted(_ environment: AppEnvironment, _ entryID: UUID, atDay day: Int32) throws {
        let entry = try XCTUnwrap(try environment.writer.entry(id: entryID))
        try environment.writer.markDeleted(entry, at: DateOnly(key: day).date)
    }

    @discardableResult
    private func makeSubscription(_ environment: AppEnvironment, firstBillingDay: Int32) throws -> UUID {
        let categoryID = try environment.writer
            .fetch(QueryDescriptors.categories(of: .expense)).first?.id
        let accountID = try environment.writer.fetch(QueryDescriptors.accounts()).first?.id

        var draft = SubscriptionDraft()
        draft.name = "视频会员"
        draft.amount = 2500
        draft.cycleUnit = .month
        draft.cycleValue = 1
        draft.firstBillingDay = firstBillingDay
        draft.categoryID = categoryID
        draft.accountID = accountID
        return try environment.subscription.create(draft, today: today).subscriptionID
    }
}
