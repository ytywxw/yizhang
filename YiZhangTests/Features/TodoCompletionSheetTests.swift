//
//  TodoCompletionSheetTests.swift
//  一账Tests / Features
//
//  T18 的验收，重点是**下拽取消要回滚完成状态**这一条时序：
//  `complete()` 会先置 done 再返回请求（刻意的），所以"用户改主意"这条路径
//  必须显式 `reopen`。写错的话待办会永久停在"已完成但没记账"，而用户从没确认过。
//
//  其余四条：
//  ② 金额为空时主按钮禁用（0 元不是一笔账）；
//  ③ 预填预计金额；`hasEstimatedAmount == false` 时留空；
//  ④ 「不记账」→ 待办保持完成、账目表零变化；
//  ⑤ 「完成并记账」→ 生成一笔 todo 来源的账目并回写关联。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class TodoCompletionSheetTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    // MARK: - ③ 预填

    func testPrefillsEstimatedAmount() throws {
        let sut = try makeSUT()
        let (_, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)

        XCTAssertEqual(viewModel.amountText, AmountInput.text(from: Money(cents: 8600)))
        XCTAssertEqual(viewModel.amount, Money(cents: 8600))
        XCTAssertEqual(viewModel.title, "「买菜」完成了吗？")
        XCTAssertNotNil(viewModel.categoryID, "分类要有默认值（请求里的或第一个）")
        XCTAssertNotNil(viewModel.accountID)
    }

    func testAmountIsEmptyWhenNoEstimate() throws {
        let sut = try makeSUT()
        let (_, request) = try sut.openExpenseTodo(estimated: 5000, hasEstimated: false)
        let viewModel = sut.sheet(request: request)

        XCTAssertTrue(viewModel.isAmountEmpty, "没勾「有预计金额」时确认条金额框要是空的，让用户自己填")
        XCTAssertNil(viewModel.amount)
        XCTAssertFalse(viewModel.canConfirm)
    }

    // MARK: - ② 金额为空 / 0 时主按钮禁用

    func testConfirmIsDisabledForEmptyOrZeroAmount() throws {
        let sut = try makeSUT()
        let (_, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)

        viewModel.amountText = ""
        XCTAssertFalse(viewModel.canConfirm)
        XCTAssertEqual(
            viewModel.confirmDisabledReason, "填个金额才能记账；不想记就选「不记账」"
        )

        viewModel.amountText = "0"
        XCTAssertFalse(viewModel.canConfirm, "0 元不是一笔账，不该走「完成并记账」")
        XCTAssertEqual(
            viewModel.confirmDisabledReason, "金额要大于 0；不想记就选「不记账」"
        )

        viewModel.amountText = "86"
        XCTAssertTrue(viewModel.canConfirm)
        XCTAssertNil(viewModel.confirmDisabledReason)
    }

    func testConfirmWithEmptyAmountDoesNothing() throws {
        let sut = try makeSUT()
        let (id, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)
        viewModel.amountText = ""

        XCTAssertNil(viewModel.confirm())
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(try sut.entryCount(), 0)
        XCTAssertFalse(viewModel.didResolve)
        XCTAssertEqual(try sut.todo(id: id)?.status, .done, "没给答案时状态先保持 done，等回滚")
    }

    // MARK: - ① 下拽取消：回滚完成状态（本批最关键的一条）

    func testDismissRollsBackCompletionToOpen() throws {
        let sut = try makeSUT()
        let (id, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)

        // `complete()` 已经把待办置成 done —— 这就是"时序"的起点
        XCTAssertEqual(try sut.todo(id: id)?.status, .done)
        XCTAssertNotNil(try sut.todo(id: id)?.completedAt)

        // 用户下拽关闭（SwiftUI 会在 onDisappear 里调这个）
        viewModel.rollbackCompletionIfNeeded()

        let todo = try XCTUnwrap(try sut.todo(id: id))
        XCTAssertEqual(todo.status, .open, "下拽取消 = 什么都没发生，待办必须退回「未完成」")
        XCTAssertNil(todo.completedAt, "完成时刻也要清掉，否则列表里会出现一条没完成却有完成时间的待办")
        XCTAssertNil(todo.linkedEntryID)
        XCTAssertEqual(try sut.entryCount(), 0, "回滚不该留下任何账目")
    }

    func testRollbackIsIdempotentAfterConfirm() throws {
        let sut = try makeSUT()
        let (id, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)
        viewModel.amountText = "86"

        XCTAssertNotNil(viewModel.confirm())
        XCTAssertTrue(viewModel.didResolve)
        XCTAssertEqual(try sut.entryCount(), 1)

        // 确认后 sheet 自己 dismiss，会再走一次 onDisappear：
        // 这次绝不能把状态回滚掉（否则"记完账待办又变回未完成"）
        viewModel.rollbackCompletionIfNeeded()

        XCTAssertEqual(try sut.todo(id: id)?.status, .done, "确认过之后回滚必须变成 no-op")
        XCTAssertEqual(try sut.entryCount(), 1)
    }

    // MARK: - ④ 不记账

    func testSkipEntryKeepsDoneAndWritesNothing() throws {
        let sut = try makeSUT()
        let (id, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)

        XCTAssertEqual(viewModel.skipEntry(), "已完成，没有记账")

        XCTAssertTrue(viewModel.didResolve)
        XCTAssertEqual(try sut.todo(id: id)?.status, .done, "「不记账」是完成，不是取消")
        XCTAssertNil(try sut.todo(id: id)?.linkedEntryID)
        XCTAssertEqual(try sut.entryCount(), 0, "R-TODO-4：不记账就一笔都不能有")

        // 之后即使再触发一次 onDisappear 也不能回滚
        viewModel.rollbackCompletionIfNeeded()
        XCTAssertEqual(try sut.todo(id: id)?.status, .done)
    }

    // MARK: - ⑤ 完成并记账

    func testConfirmCreatesTodoSourcedEntryAndLinksIt() throws {
        let sut = try makeSUT()
        let (id, request) = try sut.openExpenseTodo(estimated: 8600, hasEstimated: true)
        let viewModel = sut.sheet(request: request)
        viewModel.amountText = "88.5"

        let message = try XCTUnwrap(viewModel.confirm())

        XCTAssertTrue(message.contains("已完成"))
        let entries = try sut.liveEntries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.amount, 8850, "记的是用户填的实际金额")
        XCTAssertEqual(entry.source, .todo)
        XCTAssertEqual(entry.sourceRefID, id)
        XCTAssertEqual(entry.occurredDay, DateOnly(request.completedAt).key, "发生日 = 完成当天")
        XCTAssertEqual(entry.note, "买菜")

        let todo = try XCTUnwrap(try sut.todo(id: id))
        XCTAssertEqual(todo.status, .done)
        XCTAssertEqual(todo.linkedEntryID, entry.id, "回写关联账目")
        XCTAssertEqual(todo.estimatedAmount, 8600, "R-TODO-6：实际 88.5 不能覆盖预计 86")
    }

    func testConfirmWithEditedCategoryUsesIt() throws {
        let sut = try makeSUT()
        let (_, request) = try sut.openExpenseTodo(estimated: 3000, hasEstimated: true)
        let viewModel = sut.sheet(request: request)
        let other = try XCTUnwrap(viewModel.categories.first { $0.id != viewModel.categoryID })

        viewModel.amountText = "30"
        viewModel.select(categoryID: other.id)
        XCTAssertNotNil(viewModel.confirm())

        let entry = try XCTUnwrap(try sut.liveEntries().first)
        XCTAssertEqual(entry.category?.id, other.id, "用户在确认条里改的分类要生效")
    }

    // MARK: - 工具

    @MainActor
    private struct SUT {
        let environment: AppEnvironment
        let writer: LedgerWriter

        /// 建一条带花销的待办并勾完成（返回待办 id 与完成请求）。
        func openExpenseTodo(
            estimated: Int64,
            hasEstimated: Bool
        ) throws -> (id: UUID, request: TodoCompletionRequest) {
            let id = try environment.todo.create(
                TodoDraft(
                    title: "买菜",
                    dueDay: 20261121,
                    hasExpense: true,
                    hasEstimatedAmount: hasEstimated,
                    estimatedAmount: estimated
                )
            )
            let request = try environment.todo.complete(id: id)
            return (id, request)
        }

        func sheet(request: TodoCompletionRequest) -> TodoCompletionSheetViewModel {
            let viewModel = TodoCompletionSheetViewModel()
            viewModel.attach(environment, request: request)
            return viewModel
        }

        func todo(id: UUID) throws -> Todo? {
            try environment.todo.todo(id: id)
        }

        func liveEntries() throws -> [LedgerEntry] {
            try environment.readContext
                .fetch(QueryDescriptors.allEntries())
                .filter { $0.deletedAt == nil }
        }

        func entryCount() throws -> Int {
            try liveEntries().count
        }
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        return SUT(environment: environment, writer: LedgerWriter(container: container))
    }
}
