//
//  LedgerHomeViewModelTests.swift
//  一账Tests / Features
//
//  验证 T08 首页的取数与聚合。这批断言的重点是**数字必须自洽**：
//  ① 分组正确（按日倒序、同一天合成一组）；
//  ② 当天合计正确，且**转账不计入**支出/收入；
//  ③ 较上月百分比用整数算，且**上月为 0 时不算百分比**（除以 0 会显示「+∞%」）；
//  ④ 今日速览：7 天内的订阅 + 今天及逾期的待办；
//  ⑤ 月份不能翻到未来。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class LedgerHomeViewModelTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    // MARK: - ① 分组

    func testGroupsAreBuiltByDayInDescendingOrder() throws {
        let environment = try makeEnvironment()

        try addEntry(day: 20261120, amount: 2800, note: "午饭", in: environment)
        try addEntry(day: 20261120, amount: 600, note: "地铁", in: environment)
        try addEntry(day: 20261118, amount: 8650, note: "超市", in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.groups.count, 2, "两个不同的日子 → 两组")
        XCTAssertEqual(viewModel.groups.map(\.day.key), [20261120, 20261118], "日期倒序")
        XCTAssertEqual(viewModel.groups[0].rows.count, 2, "同一天的两笔在同一组")
        XCTAssertEqual(
            viewModel.groups[0].rows.map(\.note),
            ["地铁", "午饭"],
            "组内按创建时间倒序：后插入的「地铁」在前（列表不能每次刷新都换位置）"
        )
        XCTAssertEqual(viewModel.entryCount, 3)
    }

    // MARK: - ② 合计

    func testDayTotalsAndMonthOverviewExcludeTransfers() throws {
        let environment = try makeEnvironment()

        try addEntry(day: 20261120, amount: 2800, note: "午饭", in: environment)
        try addEntry(day: 20261120, amount: 600, note: "地铁", in: environment)
        try addEntry(day: 20261120, amount: 8650, note: "超市", in: environment)
        try addEntry(day: 20261120, amount: 1_200_000, note: "工资", type: .income, in: environment)
        // 转账 ¥500.00：绝不能进支出/收入（这是最容易算错的一条）
        try addEntry(day: 20261120, amount: 50000, note: "转进储蓄卡", type: .transfer, in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        let group = try XCTUnwrap(viewModel.groups.first)
        XCTAssertEqual(group.expense, Money(cents: 12_050), "2800 + 600 + 8650")
        XCTAssertEqual(group.income, Money(cents: 1_200_000))

        XCTAssertEqual(viewModel.overview.expense, Money(cents: 12_050))
        XCTAssertEqual(viewModel.overview.income, Money(cents: 1_200_000))
        XCTAssertEqual(
            viewModel.overview.balance,
            Money(cents: 1_200_000 - 12_050),
            "结余 = 收入 - 支出"
        )

        // 分组头合计相加必须等于概览卡（同源断言）
        let summed = viewModel.groups.reduce(Int64(0)) { $0 + $1.expense.cents }
        XCTAssertEqual(summed, viewModel.overview.expense.cents, "分组头相加 = 概览卡支出")
    }

    func testOtherMonthEntriesAreNotCounted() throws {
        let environment = try makeEnvironment()
        try addEntry(day: 20261120, amount: 1000, in: environment)
        try addEntry(day: 20261015, amount: 999_900, in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.overview.expense, Money(cents: 1000), "上月的账目不能算进本月")
        XCTAssertEqual(viewModel.previousOverview.expense, Money(cents: 999_900))
    }

    // MARK: - ③ 较上月

    func testComparisonUsesIntegerPercent() throws {
        let environment = try makeEnvironment()
        try addEntry(day: 20261015, amount: 10000, in: environment)   // 上月 ¥100.00
        try addEntry(day: 20261120, amount: 11240, in: environment)   // 本月 ¥112.40

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.comparison.direction, .increase)
        XCTAssertEqual(viewModel.comparison.magnitudeThousandths, 124)
        XCTAssertEqual(viewModel.comparison.text, "较上月 ▲12.4%")
    }

    func testComparisonHandlesZeroPreviousMonthWithoutDividingByZero() throws {
        let environment = try makeEnvironment()
        try addEntry(day: 20261120, amount: 5000, in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(
            viewModel.comparison.direction,
            .unavailable,
            "上月为 0 → 不计算百分比（除以 0 会得到「+∞%」）"
        )
        XCTAssertEqual(viewModel.comparison.text, "上月没有支出")
    }

    func testComparisonDecreaseIsGreenDirection() throws {
        let environment = try makeEnvironment()
        try addEntry(day: 20261015, amount: 20000, in: environment)
        try addEntry(day: 20261120, amount: 15000, in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.comparison.direction, .decrease)
        XCTAssertEqual(viewModel.comparison.text, "较上月 ▼25.0%")
    }

    // MARK: - ④ 今日速览

    func testGlanceCountsSubscriptionsWithinSevenDaysAndTodosDueToday() throws {
        let environment = try makeEnvironment()

        // 7 天内要扣的订阅：今天 +3 天
        _ = try environment.subscription.create(
            SubscriptionDraft(
                name: "视频会员",
                amount: 2500,
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.adding(days: 3).key
            ),
            today: today
        )
        // 10 天后才扣：不该进速览
        _ = try environment.subscription.create(
            SubscriptionDraft(
                name: "云盘",
                amount: 12000,
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.adding(days: 10).key
            ),
            today: today
        )

        try addTodo(dueDay: today.key, in: environment)                       // 今天到期 → 算
        try addTodo(dueDay: today.adding(days: -2).key, in: environment)      // 逾期未完成 → 算
        try addTodo(dueDay: today.adding(days: 3).key, in: environment)       // 三天后 → 不算

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.glance.subscriptionCount, 1, "7 天窗口内只有 1 笔")
        XCTAssertEqual(viewModel.glance.subscriptionTotal, Money(cents: 2500))
        XCTAssertEqual(viewModel.glance.todoCount, 2, "今天到期 + 已逾期，共 2 件")
        XCTAssertFalse(viewModel.glance.isEmpty)
    }

    func testGlanceIsEmptyWhenNothingIsDue() throws {
        let environment = try makeEnvironment()
        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertTrue(viewModel.glance.isEmpty, "没有待办也没有近期订阅 → 整条速览隐藏")
    }

    // MARK: - ④b 待确认小计（V1.1 F-SUB-13 / PRD 2.4-1）

    /// 首页「含待确认 1 笔 ¥25.00」的接线。
    ///
    /// 这条断言针对的是一个**静默失败**：`GlanceModel.pendingCount` 若某天被人
    /// 删掉赋值（或 `makeGlance` 忘了传），首页会一直显示"没有待确认"，
    /// 而全量测试仍然全绿——用户于是永远发现不了那笔等他核对的账。
    func testGlanceReportsPendingCountAndAmount() throws {
        let environment = try makeEnvironment()
        _ = try addPendingEntry(amount: 2500, in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.glance.pendingCount, 1, "PRD 2.4-1：首页要显示「含待确认 1 笔」")
        XCTAssertEqual(
            viewModel.glance.pendingAmount, Money(cents: 2500),
            "金额必须与笔数同源（都来自 ledger.pendingSummary()）"
        )
    }

    /// 没有待确认时必须真的是 0。
    ///
    /// 只有"有"的那条断言时，`pendingCount` 被写死成 `1` 也能过；
    /// 加上这条，写死任何一个非零常量都会红。
    func testGlanceReportsZeroPendingWhenNoneExists() throws {
        let environment = try makeEnvironment()
        try addEntry(day: today.key, amount: 2500, note: "手记一笔", in: environment)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.glance.pendingCount, 0, "手动记账已确认，不是待确认")
        XCTAssertEqual(viewModel.glance.pendingAmount, .zero)
    }

    /// 进回收站的待确认账目不能继续算在首页小计里（软删即"当前不存在"）。
    func testGlanceExcludesSoftDeletedPendingEntry() throws {
        let environment = try makeEnvironment()
        let id = try addPendingEntry(amount: 2500, in: environment)
        XCTAssertEqual(
            try environment.ledger.pendingSummary().count, 1,
            "前置条件：删之前确实有 1 笔待确认"
        )

        let entry = try XCTUnwrap(try environment.writer.entry(id: id))
        try environment.writer.markDeleted(entry, at: today.date)

        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.glance.pendingCount, 0, "回收站里的账不该继续催用户核对")
        XCTAssertEqual(viewModel.glance.pendingAmount, .zero)
    }

    // MARK: - ⑤ 月份切换

    func testMonthCannotGoBeyondCurrentMonth() throws {
        let environment = try makeEnvironment()
        let viewModel = LedgerHomeViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.monthKey, 202611)
        XCTAssertTrue(viewModel.isCurrentMonth)
        XCTAssertFalse(viewModel.canGoNextMonth)

        viewModel.goNextMonth()
        XCTAssertEqual(viewModel.monthKey, 202611, "不能翻到未来月份")

        viewModel.goPreviousMonth()
        XCTAssertEqual(viewModel.monthKey, 202610)
        XCTAssertTrue(viewModel.canGoNextMonth)

        viewModel.goNextMonth()
        XCTAssertEqual(viewModel.monthKey, 202611)

        viewModel.goPreviousMonth()
        viewModel.goToCurrentMonth()
        XCTAssertEqual(viewModel.monthKey, 202611, "「回到本月」")
    }

    func testMonthArithmeticCrossesYearBoundary() {
        XCTAssertEqual(LedgerHomeViewModel.previousMonth(of: 202601), 202512)
        XCTAssertEqual(LedgerHomeViewModel.nextMonth(of: 202512), 202601)
        XCTAssertNil(LedgerHomeViewModel.previousMonth(of: 0))
    }

    // MARK: - 工具

    private func makeEnvironment() throws -> AppEnvironment {
        let container = try ModelContainerFactory.make(inMemory: true)
        return try AppEnvironment(container: container)
    }

    private func firstCategoryID(of type: EntryType, in environment: AppEnvironment) throws -> UUID {
        let categories = try environment.readContext.fetch(
            QueryDescriptors.categories(of: type, includeHidden: false)
        )
        return try XCTUnwrap(categories.first?.id)
    }

    private func firstAccountID(in environment: AppEnvironment) throws -> UUID {
        let accounts = try environment.readContext.fetch(
            QueryDescriptors.accounts(includeArchived: false)
        )
        return try XCTUnwrap(accounts.first?.id)
    }

    @discardableResult
    private func addEntry(
        day: Int32,
        amount: Int64,
        note: String = "",
        type: EntryType = .expense,
        in environment: AppEnvironment
    ) throws -> UUID {
        var draft = EntryDraft(typeRaw: type.raw, amount: amount, occurredDay: day)
        draft.note = note
        draft.accountID = try firstAccountID(in: environment)

        switch type {
        case .expense, .income:
            draft.categoryID = try firstCategoryID(of: type, in: environment)
        case .transfer:
            let accounts = try environment.readContext.fetch(
                QueryDescriptors.accounts(includeArchived: false)
            )
            draft.toAccountID = accounts.dropFirst().first?.id
        }

        let outcome = try environment.ledger.create(draft)
        return try XCTUnwrap(outcome.entryID)
    }

    /// 造一笔**待确认**的订阅来源账目。
    ///
    /// `confirmRaw` 显式给 `pending` 而不是留 `nil` 让业务层判定：本用例测的是
    /// "首页小计有没有接上 `pendingSummary()`"这条**接线**，不是"哪天算待确认"这条规则。
    /// 规则由 `EntryConfirmationTests` 单独覆盖；这里若依赖 `todayProvider()` 的窗口，
    /// 断言会随系统时钟漂移（真实今天是几号，决定 20261121 是否落在 7 天内）。
    @discardableResult
    private func addPendingEntry(amount: Int64, in environment: AppEnvironment) throws -> UUID {
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: amount, occurredDay: today.key)
        draft.sourceRaw = EntrySource.subscription.raw
        draft.categoryID = try firstCategoryID(of: .expense, in: environment)
        draft.accountID = try firstAccountID(in: environment)
        draft.confirmRaw = EntryConfirmation.pending.raw
        // 幂等键必须每次唯一，否则第二笔会被静默跳过（`InsertOutcome.skippedDuplicate`）
        draft.sourceRefID = UUID()
        draft.sourceCycleKey = "cycle-\(UUID().uuidString.prefix(8))"

        let outcome = try environment.ledger.create(draft)
        return try XCTUnwrap(outcome.entryID, "待确认账目没有落库")
    }

    private func addTodo(dueDay: Int32, in environment: AppEnvironment) throws {
        let todo = Todo()
        todo.title = "演示待办"
        todo.status = .open
        todo.dueDay = dueDay
        todo.category = try environment.readContext
            .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
            .first
        // 测试夹具：直接落库（生产代码里待办只能经 TodoService 写入，T15 补）
        environment.container.mainContext.insert(todo)
        try environment.container.mainContext.save()
    }
}
