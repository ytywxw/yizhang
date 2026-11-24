//
//  TodoListViewModelTests.swift
//  一账Tests / Features
//
//  T16 的验收：
//  ① 五段切分正确（今天 / 本周 / 以后 / 无日期 / 已完成）；
//  ② **逾期归入「今天」并标红**（`isOverdue`），不单独成组；
//  ③ 已完成默认折叠，折叠头显示总数；
//  ④ **订阅派生项不计入「今天要办 N 件」**（R-MIX-3）；
//  ⑤ 订阅扣费分组默认折叠，且不落库（它每次都是实时派生）。
//
//  另外覆盖行操作：勾完成（有花销/无花销两条路径）、移到明天、删除、撤销完成。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class TodoListViewModelTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    // MARK: - ① 五段切分

    func testGroupsSplitIntoFiveBucketsInFixedOrder() throws {
        let sut = try makeSUT()
        try sut.create(title: "今天的事", dueDay: 20261121)
        try sut.create(title: "逾期的事", dueDay: 20261118)
        try sut.create(title: "本周的事", dueDay: 20261124)
        try sut.create(title: "以后的事", dueDay: 20261215)
        try sut.create(title: "没日期的事", dueDay: 0)

        let viewModel = sut.listViewModel(today: today)

        XCTAssertEqual(
            viewModel.groups.map(\.kind),
            [.today, .thisWeek, .later, .noDate],
            "顺序必须固定：今天 → 本周 → 以后 → 无日期（已完成为空时不出现）"
        )
        XCTAssertEqual(viewModel.groups.map { $0.rows.map(\.title) }, [
            ["逾期的事", "今天的事"],   // 组内按截止日升序：逾期在前
            ["本周的事"],
            ["以后的事"],
            ["没日期的事"]
        ])
    }

    func testTodayGroupIncludesBothDueTodayAndOverdue() throws {
        let sut = try makeSUT()
        try sut.create(title: "今天", dueDay: 20261121)
        try sut.create(title: "昨天没做", dueDay: 20261120)

        let viewModel = sut.listViewModel(today: today)
        let todayGroup = try XCTUnwrap(viewModel.groups.first { $0.kind == .today })

        XCTAssertEqual(todayGroup.count, 2, "逾期不单独成组：它属于「今天」")
        let overdueRow = try XCTUnwrap(todayGroup.rows.first { $0.title == "昨天没做" })
        XCTAssertTrue(overdueRow.isOverdue, "逾期必须被标记（UI 据此标红）")
        XCTAssertEqual(overdueRow.dueText, "逾期 11月20日", "文案要显式说「逾期」，不能只靠颜色")
        let todayRow = try XCTUnwrap(todayGroup.rows.first { $0.title == "今天" })
        XCTAssertFalse(todayRow.isOverdue)
        XCTAssertEqual(todayRow.dueText, "截止 11月21日")
    }

    func testWeekBoundaryIsSixDaysAhead() throws {
        XCTAssertEqual(
            TodoListViewModel.groupKind(
                of: try makeTodo(dueDay: 20261127),
                today: today,
                weekEnd: today.adding(days: 6)
            ),
            .thisWeek,
            "今天 +6 天仍算「本周」"
        )
        XCTAssertEqual(
            TodoListViewModel.groupKind(
                of: try makeTodo(dueDay: 20261128),
                today: today,
                weekEnd: today.adding(days: 6)
            ),
            .later,
            "今天 +7 天算「以后」"
        )
    }

    // MARK: - ③ 已完成

    func testCompletedGroupIsCollapsedByDefaultAndCountsAll() throws {
        let sut = try makeSUT()
        try sut.create(title: "已完成 1", dueDay: 20261121)
        try sut.create(title: "已完成 2", dueDay: 20261120)
        try sut.create(title: "还没做", dueDay: 20261121)

        var viewModel = sut.listViewModel(today: today)
        for row in viewModel.groups.first(where: { $0.kind == .today })?.rows ?? [] where row.title.hasPrefix("已完成") {
            _ = viewModel.complete(id: row.id)
        }

        XCTAssertTrue(viewModel.isCompletedCollapsed, "已完成默认折叠")
        let completed = try XCTUnwrap(viewModel.completedGroup)
        XCTAssertEqual(completed.count, 2, "折叠头要显示总数「已完成 2」")
        XCTAssertEqual(completed.detailText, "2")
        XCTAssertFalse(
            viewModel.visibleGroups.contains { $0.kind == .done },
            "折叠时「已完成」不能出现在可见分组里"
        )
        XCTAssertTrue(completed.rows.allSatisfy(\.isDone), "已完成的行要带 isDone（UI 画删除线）")

        viewModel.toggleCompletedCollapsed()
        XCTAssertTrue(viewModel.visibleGroups.contains { $0.kind == .done })
    }

    // MARK: - ④⑤ 订阅派生项

    func testSubscriptionDueItemsDoNotCountTowardToday() throws {
        let sut = try makeSUT()
        try sut.create(title: "唯一一件正事", dueDay: 20261121)
        // 造一条今天扣费的订阅
        _ = try sut.environment.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261121),
            today: today
        )

        let viewModel = sut.listViewModel(today: today)

        XCTAssertEqual(viewModel.dueItems.count, 1, "订阅扣费要出现（派生项）")
        XCTAssertEqual(
            viewModel.todayCount, 1,
            "R-MIX-3：订阅扣费不计入「今天要办 N 件」——那个数字只回答「我要动手几件事」"
        )
        XCTAssertEqual(viewModel.overdueCount, 0)
        XCTAssertEqual(try sut.entryCount(), 0, "派生项绝不落库、更不生成账目（D4）")
    }

    func testDueSectionIsCollapsedByDefaultAndDerivedWithoutPersisting() throws {
        let sut = try makeSUT()
        _ = try sut.environment.subscription.create(
            SubscriptionDraft(name: "云盘", amount: 12000, firstBillingDay: 20261123),
            today: today
        )

        let viewModel = sut.listViewModel(today: today)

        XCTAssertFalse(viewModel.isDueSectionExpanded, "订阅扣费分组默认折叠")
        XCTAssertEqual(viewModel.dueItems.first?.name, "云盘")
        XCTAssertEqual(viewModel.dueTotal, Money(cents: 12000))
        XCTAssertEqual(try sut.todoCount(), 0, "订阅扣费不能被写成待办")

        viewModel.toggleDueSection()
        XCTAssertTrue(viewModel.isDueSectionExpanded)
    }

    func testEmptyStateIgnoresSubscriptionDerivedItems() throws {
        let sut = try makeSUT()
        _ = try sut.environment.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20261122),
            today: today
        )

        let viewModel = sut.listViewModel(today: today)

        XCTAssertTrue(viewModel.isEmpty, "只有订阅扣费、没有待办时仍然是空态（否则空态永远不出现）")
        XCTAssertEqual(viewModel.todayCount, 0)
    }

    // MARK: - 行操作

    func testCompleteWithoutExpenseFinishesDirectly() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "取快递", dueDay: 20261121)
        let viewModel = sut.listViewModel(today: today)

        let request = viewModel.complete(id: id)

        XCTAssertNil(request, "无花销：不弹确认条，零打扰（R-TODO-5）")
        XCTAssertEqual(try sut.todo(id: id)?.status, .done)
        XCTAssertEqual(try sut.entryCount(), 0)
        XCTAssertEqual(viewModel.todayCount, 0, "完成之后今天计数要跟着掉")
    }

    func testCompleteWithExpenseReturnsRequestAndMarksDone() throws {
        let sut = try makeSUT()
        let id = try sut.create(
            title: "买菜",
            dueDay: 20261121,
            hasExpense: true,
            estimatedAmount: 8600
        )
        let viewModel = sut.listViewModel(today: today)

        let request = try XCTUnwrap(viewModel.complete(id: id))

        XCTAssertTrue(request.needsConfirmation)
        XCTAssertEqual(request.suggestedAmount, Money(cents: 8600))
        XCTAssertEqual(try sut.todo(id: id)?.status, .done, "第一步必须立刻置 done")
        XCTAssertEqual(try sut.entryCount(), 0, "确认之前一笔账都不能有（R-TODO-8）")
    }

    func testPostponeMovesTodoToTomorrow() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "拖一下", dueDay: 20261121)
        let viewModel = sut.listViewModel(today: today)

        let message = try XCTUnwrap(viewModel.postponeToTomorrow(id: id))

        XCTAssertTrue(message.contains("已移到明天"))
        XCTAssertEqual(try sut.todo(id: id)?.dueDay, 20261122)
        XCTAssertEqual(viewModel.todayCount, 0, "移到明天后不该再占今天的名额")
        XCTAssertEqual(
            viewModel.groups.first(where: { $0.kind == .thisWeek })?.count, 1
        )
    }

    func testDeleteRemovesOpenTodoEntirely() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "不要了", dueDay: 20261121)
        let viewModel = sut.listViewModel(today: today)

        XCTAssertEqual(viewModel.delete(id: id), "已删除待办")

        XCTAssertNil(try sut.todo(id: id), "D23：未完成待办是真删，不是软删")
        XCTAssertTrue(viewModel.isEmpty)
    }

    func testReopenKeepsOrDeletesLinkedEntry() throws {
        let sut = try makeSUT()
        let keepID = try sut.completedTodoWithEntry(title: "保留", amount: 5000)
        let dropID = try sut.completedTodoWithEntry(title: "删掉", amount: 3000)
        let viewModel = sut.listViewModel(today: today)
        XCTAssertEqual(try sut.entryCount(), 2)

        XCTAssertEqual(viewModel.reopen(id: keepID, keepEntry: true), "已撤销完成，账目保留")
        XCTAssertEqual(try sut.entryCount(), 2, "保留账目：那笔钱确实花了")
        XCTAssertEqual(try sut.todo(id: keepID)?.status, .open)

        XCTAssertEqual(viewModel.reopen(id: dropID, keepEntry: false), "已撤销完成，账目已删除")
        XCTAssertEqual(try sut.entryCount(), 1, "删除账目：软删掉那笔")
        XCTAssertEqual(try sut.todo(id: dropID)?.status, .open)
    }

    // MARK: - D22：关联账目被删时仍能识别

    func testRowFlagsDeletedLinkedEntry() throws {
        let sut = try makeSUT()
        let id = try sut.completedTodoWithEntry(title: "买了又删", amount: 4200)
        let linkedID = try XCTUnwrap(try sut.todo(id: id)?.linkedEntryID)
        // 直接软删那笔账（模拟用户在账目详情里删掉它）
        _ = try sut.writer.softDelete(id: linkedID, at: Date())

        let viewModel = sut.listViewModel(today: today)
        let row = try XCTUnwrap(
            viewModel.completedGroup?.rows.first { $0.id == id }
        )

        XCTAssertTrue(row.hasLinkedEntry, "D22：关联关系保留")
        XCTAssertTrue(row.linkedEntryDeleted, "但标记出「账目已删除」，供详情页显示")
    }

    // MARK: - 工具

    @MainActor
    private struct SUT {
        let environment: AppEnvironment
        let writer: LedgerWriter

        func listViewModel(today: DateOnly) -> TodoListViewModel {
            let viewModel = TodoListViewModel(today: today)
            viewModel.attach(environment)
            return viewModel
        }

        @discardableResult
        func create(
            title: String,
            dueDay: Int32,
            hasExpense: Bool = false,
            estimatedAmount: Int64 = 0
        ) throws -> UUID {
            try environment.todo.create(
                TodoDraft(
                    title: title,
                    dueDay: dueDay,
                    hasExpense: hasExpense,
                    hasEstimatedAmount: estimatedAmount > 0,
                    estimatedAmount: estimatedAmount
                )
            )
        }

        func completedTodoWithEntry(title: String, amount: Int64) throws -> UUID {
            let id = try environment.todo.create(
                TodoDraft(
                    title: title,
                    dueDay: 20261121,
                    hasExpense: true,
                    hasEstimatedAmount: true,
                    estimatedAmount: amount
                )
            )
            let request = try environment.todo.complete(id: id)
            _ = try environment.todo.confirmCompletion(
                CompletionConfirmation(amountCents: amount),
                for: request
            )
            return id
        }

        func todo(id: UUID) throws -> Todo? {
            try environment.todo.todo(id: id)
        }

        func todoCount() throws -> Int {
            try environment.todo.todos().count
        }

        func entryCount() throws -> Int {
            try environment.readContext
                .fetch(QueryDescriptors.allEntries())
                .filter { $0.deletedAt == nil }
                .count
        }
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        return SUT(environment: environment, writer: LedgerWriter(container: container))
    }

    /// 造一个只用于分组判断的 `Todo`（不落库）。
    private func makeTodo(dueDay: Int32) throws -> Todo {
        let todo = Todo()
        todo.dueDay = dueDay
        return todo
    }
}
