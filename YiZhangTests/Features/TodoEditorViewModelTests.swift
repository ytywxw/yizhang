//
//  TodoEditorViewModelTests.swift
//  一账Tests / Features
//
//  T17 的验收：
//  ① 标题为空拦得住（并且什么都不写）；
//  ② **没勾「有花销」时完全不校验金额**——填了乱码也不该拦（那是无关字段）；
//  ③ 勾了花销但金额留空 → 可以保存，且详情页显示「未记录」（`estimatedText == nil`）；
//  ④ 重复规则的间隔（1…366，`none` 时归一为 1）；
//  ⑤ 详情态：「预计」与「已记账」是两个独立字段（R-TODO-6 的 UI 表达），
//     关联账目被软删时 `linkedEntryDeleted == true`（D22）。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class TodoEditorViewModelTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    // MARK: - ① 标题

    func testSaveRejectsEmptyTitleAndWritesNothing() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)

        XCTAssertFalse(viewModel.canSave)
        XCTAssertEqual(viewModel.saveDisabledReason, "请填写待办标题")
        XCTAssertNil(viewModel.save())
        XCTAssertEqual(viewModel.errorMessage, "请填写待办标题")
        XCTAssertEqual(try sut.todoCount(), 0, "校验失败不能留下半条数据")
    }

    func testSaveRejectsWhitespaceOnlyAndOverlongTitle() throws {
        let sut = try makeSUT()

        let blank = sut.editor(mode: .create, today: today)
        blank.title = "   \n"
        XCTAssertNil(blank.save())

        let long = sut.editor(mode: .create, today: today)
        long.title = String(repeating: "长", count: TodoEditorViewModel.titleLimit + 1)
        XCTAssertEqual(long.saveDisabledReason, "标题最多 60 个字")
        XCTAssertNil(long.save())
    }

    func testSaveTrimsTitle() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "  写周报  "

        let result = try XCTUnwrap(viewModel.save())

        XCTAssertTrue(result.isNew)
        XCTAssertEqual(try sut.todo(id: result.todoID)?.title, "写周报")
    }

    // MARK: - ② 无花销不校验金额

    func testAmountIsNotValidatedWhenExpenseIsOff() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "取快递"
        viewModel.hasExpense = false
        // 用户之前填过又关掉了开关：残留一个非法字符串也不该拦住保存
        viewModel.amountText = "abc"

        XCTAssertNil(viewModel.validationMessage(), "没勾花销时金额是无关字段，连格式都不该看")
        XCTAssertTrue(viewModel.canSave)

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertFalse(todo.hasExpense)
        XCTAssertNil(todo.category, "无花销不该带分类")
        XCTAssertNil(todo.account, "无花销不该带账户")
    }

    func testTurningExpenseOffClearsAmountCategoryAndAccount() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "先勾后取消"
        viewModel.setHasExpense(true)
        viewModel.amountText = "86"
        XCTAssertNotNil(viewModel.categoryID)

        viewModel.setHasExpense(false)

        XCTAssertEqual(viewModel.amountText, "", "关掉花销要把金额一起清掉，避免留下半截数据")
        XCTAssertNil(viewModel.categoryID)
        XCTAssertNil(viewModel.accountID)
    }

    // MARK: - ③ 花销金额留空

    func testExpenseWithEmptyAmountSavesAndShowsNotRecorded() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "买菜"
        viewModel.setHasExpense(true)
        viewModel.amountText = ""

        XCTAssertTrue(viewModel.hasEstimatedAmount == false)
        XCTAssertTrue(viewModel.canSave, "预计金额允许留空（留空 ≠ 0）")

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertTrue(todo.hasExpense)
        XCTAssertFalse(todo.hasEstimatedAmount, "留空要落成 hasEstimatedAmount = false，不能是 0")
        XCTAssertEqual(todo.estimatedAmount, 0)

        // 详情态：显示「未记录」而不是「¥0.00」
        let detail = sut.editor(mode: .edit(result.todoID), today: today)
        XCTAssertNil(detail.estimatedText, "预计留空 → 详情页显示「未记录」")
    }

    func testExpenseWithAmountPersistsEstimate() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "聚餐"
        viewModel.setHasExpense(true)
        viewModel.amountText = "200"

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertTrue(todo.hasEstimatedAmount)
        XCTAssertEqual(todo.estimatedAmount, 20000)

        let detail = sut.editor(mode: .edit(result.todoID), today: today)
        XCTAssertEqual(detail.estimatedText, Money(cents: 20000).formatted())
    }

    // MARK: - ④ 重复规则与间隔

    func testRepeatRuleNormalisesIntervalWhenTurnedOff() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "每周复盘"
        viewModel.select(repeatRule: .weekly)
        viewModel.repeatInterval = 2
        XCTAssertEqual(viewModel.repeatText, "每周（每 2 次）")

        viewModel.select(repeatRule: .none)
        XCTAssertEqual(viewModel.repeatInterval, 1, "关掉重复要把间隔归 1，不能留个孤儿数字")

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertEqual(todo.repeatRule, .none)
        XCTAssertEqual(todo.repeatInterval, 1)
    }

    func testRepeatIntervalOutOfRangeIsRejected() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "越界"
        viewModel.select(repeatRule: .daily)
        viewModel.repeatInterval = 0

        XCTAssertEqual(viewModel.saveDisabledReason, "重复间隔需要在 1 到 366 之间")
        XCTAssertNil(viewModel.save())
        XCTAssertEqual(try sut.todoCount(), 0)
    }

    func testRepeatIntervalIsPersisted() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "每两周"
        viewModel.hasDueDate = true
        viewModel.dueDay = today
        viewModel.select(repeatRule: .weekly)
        viewModel.repeatInterval = 2

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertEqual(todo.repeatRule, .weekly)
        XCTAssertEqual(todo.repeatInterval, 2)
    }

    // MARK: - ⑤ 详情态：预计 / 已记账两行并存

    func testDetailShowsEstimateAndRecordedSideBySide() throws {
        let sut = try makeSUT()
        let id = try sut.environment.todo.create(
            TodoDraft(
                title: "聚餐",
                dueDay: 20261121,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 10000
            )
        )
        let request = try sut.environment.todo.complete(id: id)
        _ = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 13800),
            for: request
        )

        let detail = sut.editor(mode: .edit(id), today: today)

        XCTAssertTrue(detail.isDone)
        XCTAssertEqual(detail.estimatedText, Money(cents: 10000).formatted(), "预计还是 100")
        XCTAssertEqual(detail.recordedText, Money(cents: 13800).formatted(), "已记账是 138")
        XCTAssertNotEqual(
            detail.estimatedText, detail.recordedText,
            "R-TODO-6：两个数字必须分得开，合并了就再也拆不回来"
        )
        XCTAssertNotNil(detail.linkedEntryID)
        XCTAssertFalse(detail.linkedEntryDeleted)
    }

    func testDetailFlagsDeletedLinkedEntry() throws {
        let sut = try makeSUT()
        let id = try sut.environment.todo.create(
            TodoDraft(title: "买完又删", hasExpense: true, hasEstimatedAmount: true, estimatedAmount: 4200)
        )
        let request = try sut.environment.todo.complete(id: id)
        _ = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 4200),
            for: request
        )
        let linkedID = try XCTUnwrap(try sut.environment.todo.todo(id: id)?.linkedEntryID)
        _ = try sut.writer.softDelete(id: linkedID, at: Date())

        let detail = sut.editor(mode: .edit(id), today: today)

        XCTAssertEqual(detail.linkedEntryID, linkedID, "D22：关联不清掉，撤销软删才能恢复")
        XCTAssertTrue(detail.linkedEntryDeleted, "但要知道它已被删，UI 显示「关联账目已删除」")
    }

    func testReopenClearsDetailState() throws {
        let sut = try makeSUT()
        let id = try sut.environment.todo.create(
            TodoDraft(title: "撤销我", hasExpense: true, hasEstimatedAmount: true, estimatedAmount: 1000)
        )
        let request = try sut.environment.todo.complete(id: id)
        _ = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 1000),
            for: request
        )
        let detail = sut.editor(mode: .edit(id), today: today)

        XCTAssertEqual(detail.reopen(keepEntry: true), "已撤销完成，账目保留")

        XCTAssertFalse(detail.isDone)
        XCTAssertNil(detail.linkedEntryID)
        XCTAssertNil(detail.recordedText)
        XCTAssertEqual(try sut.environment.todo.todo(id: id)?.status, .open)
        XCTAssertEqual(try sut.entryCount(), 1, "保留账目")
    }

    // MARK: - 编辑不影响已生成的实例

    func testEditingRepeatRuleDoesNotTouchExistingInstance() throws {
        let sut = try makeSUT()
        let id = try sut.environment.todo.create(
            TodoDraft(title: "交房租", dueDay: 20261115, repeatRule: .monthly, repeatInterval: 1)
        )
        _ = try sut.environment.todo.complete(id: id)
        let spawned = try XCTUnwrap(try sut.environment.todo.openTodos().first)
        XCTAssertEqual(spawned.dueDay, 20261215)

        let editor = sut.editor(mode: .edit(id), today: today)
        editor.select(repeatRule: .yearly)
        XCTAssertNotNil(editor.save())

        let unchanged = try XCTUnwrap(try sut.environment.todo.todo(id: spawned.id))
        XCTAssertEqual(unchanged.dueDay, 20261215, "已经生成的下一期不受这次编辑影响")
        XCTAssertEqual(unchanged.repeatRule, .monthly, "下一期保留它自己生成时的规则")
        XCTAssertEqual(try sut.environment.todo.todo(id: id)?.repeatRule, .yearly)
    }

    // MARK: - 删除

    func testDeleteRemovesTodoButKeepsEntry() throws {
        let sut = try makeSUT()
        let id = try sut.environment.todo.create(
            TodoDraft(title: "删我", hasExpense: true, hasEstimatedAmount: true, estimatedAmount: 5000)
        )
        let request = try sut.environment.todo.complete(id: id)
        _ = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 5000),
            for: request
        )
        let editor = sut.editor(mode: .edit(id), today: today)

        XCTAssertEqual(editor.delete(), "已删除待办")

        XCTAssertNil(try sut.environment.todo.todo(id: id))
        XCTAssertEqual(try sut.entryCount(), 1, "删待办不删账：钱确实花出去了")
    }

    // MARK: - 截止与提醒

    func testDueTimeIsPersistedOnlyWhenEnabled() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "有时间的待办"
        viewModel.hasDueDate = true
        viewModel.dueDay = today
        viewModel.hasDueTime = true
        viewModel.dueTimeMinutes = 18 * 60

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertEqual(todo.dueDay, today.key)
        XCTAssertEqual(todo.dueTimeMinutes, 1080)

        let noTime = sut.editor(mode: .create, today: today)
        noTime.title = "没时间的待办"
        noTime.hasDueTime = false
        let second = try XCTUnwrap(noTime.save())
        XCTAssertEqual(try sut.todo(id: second.todoID)?.dueTimeMinutes, -1)
    }

    func testNoDueDateSavesZeroKey() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "不需要日期"
        viewModel.hasDueDate = false

        let result = try XCTUnwrap(viewModel.save())
        XCTAssertEqual(try sut.todo(id: result.todoID)?.dueDay, 0, "无日期落成哨兵值 0")
    }

    func testReminderIsPersistedOnlyWhenEnabled() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.title = "要提醒"
        viewModel.reminderEnabled = true
        viewModel.reminderDay = today
        viewModel.reminderMinutes = 9 * 60

        let result = try XCTUnwrap(viewModel.save())
        let todo = try XCTUnwrap(try sut.todo(id: result.todoID))
        XCTAssertEqual(todo.reminderDay, today.key)
        XCTAssertEqual(todo.reminderMinutes, 540)
    }

    // MARK: - 工具

    @MainActor
    private struct SUT {
        let environment: AppEnvironment
        let writer: LedgerWriter

        func editor(mode: TodoEditorViewModel.Mode, today: DateOnly) -> TodoEditorViewModel {
            let viewModel = TodoEditorViewModel(mode: mode, today: today)
            viewModel.attach(environment)
            return viewModel
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
}
