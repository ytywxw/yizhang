//
//  TodoServiceTests.swift
//  一账Tests / Services
//
//  T15（PRD 附录 A.3）的落库验收，重点全在"完成"这件事的**两条路径**上：
//  ① 有花销 + 确认 → 账目在 `confirmCompletion` 之后才出现（`complete` 时一笔都不能有）；
//  ② 有花销 + 不记账 → 只有状态变化，账目表零变化；
//  ③ 无花销 → 直接完成，`needsConfirmation == false`（UI 零打扰）。
//
//  另外四条纪律各有一条用例：
//  ④ **未完成的待办绝不预留账目**（R-TODO-8）；
//  ⑤ **改金额不回写 `estimatedAmount`**（R-TODO-6）；
//  ⑥ 撤销完成两个出口（保留账目 / 软删账目，R-TODO-7）；
//  ⑦ 重复待办完成后生成下一期，标题/金额/分类继承、`completedAt` 清空、日期按规则推进。
//
//  这些用例要真容器：两步完成的关键就是"两次 save 之间数据库里是什么样"。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class TodoServiceTests: XCTestCase {

    /// 固定"今天"：2026-11-21 10:30。
    private let today = DateOnly(key: 20261121)
    /// 固定的"完成时刻"，与 `today` 同一天（账目的发生日要取它当天，不能是未来）。
    private let now = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: .current,
        year: 2026,
        month: 11,
        day: 21,
        hour: 10,
        minute: 30
    ).date ?? Date(timeIntervalSince1970: 0)

    // MARK: - ① 有花销：确认后才落账

    func testCompleteWithExpenseCreatesNoEntryUntilConfirmed() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(
            TodoDraft(
                title: "午饭",
                dueDay: 20261121,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 3000
            )
        )
        XCTAssertEqual(try sut.entryCount(), 0, "新建待办绝不能预留账目（R-TODO-8）")

        let request = try sut.service.complete(id: id, at: now)

        XCTAssertTrue(request.needsConfirmation, "带花销要弹确认条")
        XCTAssertEqual(request.suggestedAmount, Money(cents: 3000), "确认条预填预计金额")
        XCTAssertEqual(request.title, "午饭")
        XCTAssertEqual(
            try sut.entryCount(), 0,
            "第一步只置完成，账目必须等第二步——否则用户没确认就多了一笔账"
        )

        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(todo.isDone, "第一步必须真的完成（这是用户不可丢的意图）")
        XCTAssertNotNil(todo.completedAt)
        XCTAssertNil(todo.linkedEntryID, "还没记账，不能有关联")

        let outcome = try sut.service.confirmCompletion(
            CompletionConfirmation(amountCents: 2800),
            for: request
        )

        XCTAssertNotNil(outcome)
        XCTAssertTrue(outcome?.wasInserted == true)
        let entries = try sut.liveEntries()
        XCTAssertEqual(entries.count, 1, "确认之后才有一笔账")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.amount, 2800, "记的是用户填的实际金额，不是预计金额")
        XCTAssertEqual(entry.type, .expense)
        XCTAssertEqual(entry.source, .todo)
        XCTAssertEqual(entry.note, "午饭")
        XCTAssertEqual(entry.occurredDay, 20261121, "发生日 = 完成当天")
        XCTAssertEqual(entry.sourceRefID, id)
        XCTAssertEqual(entry.sourceCycleUniqueKey, "todo|\(id.uuidString)")

        let confirmed = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertEqual(confirmed.linkedEntryID, entry.id, "第二步要回写关联账目")
    }

    // MARK: - ② 有花销：选择不记账

    func testCompleteWithExpenseAndSkipWritesNothing() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(
            TodoDraft(title: "打车", hasExpense: true, hasEstimatedAmount: true, estimatedAmount: 2000)
        )
        let request = try sut.service.complete(id: id, at: now)

        let outcome = try sut.service.confirmCompletion(.skipEntry, for: request)

        XCTAssertNil(outcome, "「不记账」不是错误，返回 nil")
        XCTAssertEqual(try sut.entryCount(), 0, "R-TODO-4：用户选了不记账，就一笔都不能有")
        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(todo.isDone)
        XCTAssertNil(todo.linkedEntryID)
        XCTAssertEqual(todo.estimatedAmount, 2000, "预计金额还在，它只是没被花出去")
    }

    func testConfirmWithZeroAmountAlsoSkipsEntry() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "买水", hasExpense: true))
        let request = try sut.service.complete(id: id, at: now)

        XCTAssertNil(try sut.service.confirmCompletion(CompletionConfirmation(amountCents: 0), for: request))
        XCTAssertEqual(try sut.entryCount(), 0, "0 元等同于不记账")
    }

    // MARK: - ③ 无花销：零打扰直接完成

    func testCompleteWithoutExpenseCompletesDirectly() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "取快递", dueDay: 20261121))

        let request = try sut.service.complete(id: id, at: now)

        XCTAssertFalse(request.needsConfirmation, "R-TODO-5：没有花销不弹确认条")
        XCTAssertNil(request.suggestedAmount)
        XCTAssertNil(request.estimatedAmount)
        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(todo.isDone)
        XCTAssertEqual(try sut.entryCount(), 0)
    }

    // MARK: - ④ 未完成不预留 / 编辑不落账

    func testEditingAnOpenTodoNeverCreatesEntry() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(
            TodoDraft(title: "房租", hasExpense: true, hasEstimatedAmount: true, estimatedAmount: 250000)
        )
        try sut.service.update(
            id: id,
            changing: TodoChanges(title: "九月房租", estimatedAmount: 260000, priority: .high)
        )

        XCTAssertEqual(try sut.entryCount(), 0, "改金额、改优先级都不该产生账目")
        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(todo.isOpen)
        XCTAssertEqual(todo.estimatedAmount, 260000)
        XCTAssertNil(todo.linkedEntryID)
    }

    func testConfirmCompletionRequiresCompletedTodo() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "买菜", hasExpense: true))
        let request = try sut.service.complete(id: id, at: now)
        // 用户点了确认条之前先撤销了完成
        try sut.service.reopen(id: id, keepEntry: true)

        XCTAssertThrowsError(try sut.service.confirmCompletion(
            CompletionConfirmation(amountCents: 1000),
            for: request
        )) { error in
            XCTAssertEqual(error as? TodoError, .notCompleted, "撤销完成后迟到的确认必须被挡掉")
        }
        XCTAssertEqual(try sut.entryCount(), 0)
    }

    func testCompleteTwiceThrows() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "倒垃圾"))

        try sut.service.complete(id: id, at: now)
        XCTAssertThrowsError(try sut.service.complete(id: id, at: now)) { error in
            XCTAssertEqual(error as? TodoError, .alreadyCompleted)
        }
    }

    // MARK: - ⑤ 改金额不回写预计（R-TODO-6）

    func testConfirmedAmountDoesNotOverwriteEstimate() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(
            TodoDraft(title: "聚餐", hasExpense: true, hasEstimatedAmount: true, estimatedAmount: 10000)
        )
        let request = try sut.service.complete(id: id, at: now)
        XCTAssertEqual(request.suggestedAmount, Money(cents: 10000))

        _ = try sut.service.confirmCompletion(CompletionConfirmation(amountCents: 13800), for: request)

        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertEqual(
            todo.estimatedAmount, 10000,
            "R-TODO-6：「当初预计 100」和「实际花了 138」必须分得开，不能写回同一个字段"
        )
        XCTAssertEqual(todo.hasEstimatedAmount, true)
        XCTAssertEqual(try sut.liveEntries().first?.amount, 13800)
    }

    func testHasEstimatedAmountFalseLeavesConfirmAmountEmpty() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(
            TodoDraft(title: "随手买", hasExpense: true, hasEstimatedAmount: false, estimatedAmount: 5000)
        )

        let request = try sut.service.complete(id: id, at: now)

        XCTAssertTrue(request.needsConfirmation)
        XCTAssertNil(request.estimatedAmount, "没勾「有预计金额」时，请求里不该带金额")
        XCTAssertNil(request.suggestedAmount, "确认条的金额输入框要是空的，让用户自己填")
    }

    // MARK: - ⑥ 撤销完成的两个出口

    func testReopenKeepingEntryJustClearsTheLink() throws {
        let sut = try makeSUT()
        let id = try sut.completedTodoWithEntry(amount: 4200)

        try sut.service.reopen(id: id, keepEntry: true)

        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(todo.isOpen)
        XCTAssertNil(todo.completedAt)
        XCTAssertNil(todo.linkedEntryID, "断开关联")
        XCTAssertEqual(try sut.liveEntries().count, 1, "钱已经花出去了，账目必须留着")
    }

    func testReopenDeletingEntrySoftDeletesIt() throws {
        let sut = try makeSUT()
        let id = try sut.completedTodoWithEntry(amount: 4200)

        try sut.service.reopen(id: id, keepEntry: false)

        XCTAssertEqual(try sut.liveEntries().count, 0, "账目被软删，用户看不到了")
        XCTAssertEqual(
            try sut.entryCount(includeDeleted: true), 1,
            "软删而不是硬删：还能撤销回来（与删账的双分支语义一致）"
        )
        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(todo.isOpen)
        XCTAssertNil(todo.linkedEntryID)
    }

    func testReopenAnOpenTodoThrows() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "还书"))

        XCTAssertThrowsError(try sut.service.reopen(id: id)) { error in
            XCTAssertEqual(error as? TodoError, .notCompleted)
        }
    }

    // MARK: - ⑦ 重复待办生成下一期

    func testRepeatingTodoSpawnsNextOccurrenceOnComplete() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(
            TodoDraft(
                title: "交房租",
                dueDay: 20261115,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 250000,
                repeatRule: .monthly,
                repeatInterval: 1,
                reminderDay: 20261113
            )
        )

        let request = try sut.service.complete(id: id, at: now)

        XCTAssertTrue(request.didSpawnNextOccurrence, "完成后要顺手排下一期")
        let all = try sut.service.todos()
        XCTAssertEqual(all.count, 2, "本期已完成的 + 下一期")

        let next = try XCTUnwrap(all.first { $0.isOpen })
        XCTAssertEqual(next.title, "交房租", "标题继承")
        XCTAssertEqual(next.estimatedAmount, 250000, "预计金额继承")
        XCTAssertEqual(next.repeatRule, .monthly, "重复规则继承")
        XCTAssertEqual(next.repeatInterval, 1)
        XCTAssertEqual(next.dueDay, 20261215, "每月 15 号：下一期是 12/15")
        XCTAssertNil(next.completedAt, "下一期必须清空完成时刻")
        XCTAssertNil(next.linkedEntryID)
        XCTAssertEqual(next.reminderDay, 20261213, "提醒日按同一周期后推，T20 的通知服务要能直接拾取")
        XCTAssertNotNil(next.category, "分类继承")
        XCTAssertNotNil(next.account, "账户继承")

        let finished = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertTrue(finished.isDone)
    }

    func testNonRepeatingTodoSpawnsNothing() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "一次性事项", dueDay: 20261121))

        let request = try sut.service.complete(id: id, at: now)

        XCTAssertFalse(request.didSpawnNextOccurrence)
        XCTAssertEqual(try sut.service.todos().count, 1)
    }

    func testRepeatingTodoWithoutDueDateSpawnsNothing() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "没日期的重复", repeatRule: .weekly))

        let request = try sut.service.complete(id: id, at: now)

        XCTAssertFalse(request.didSpawnNextOccurrence, "没有截止日就没有「下一期」，不能瞎猜一个日期")
        XCTAssertEqual(try sut.service.todos().count, 1)
    }

    // MARK: - 增删改

    func testDeleteTodoKeepsLinkedEntry() throws {
        let sut = try makeSUT()
        let id = try sut.completedTodoWithEntry(amount: 5000)

        try sut.service.delete(id: id)

        XCTAssertTrue(try sut.service.todos().isEmpty)
        XCTAssertEqual(
            try sut.liveEntries().count, 1,
            "删待办不删账：那笔钱确实花出去了，只是来源会显示「已删除」"
        )
    }

    func testUpdateDisablingExpenseClearsCategoryAndAccount() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "本来要花钱", hasExpense: true))
        let before = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertNotNil(before.category)

        try sut.service.update(id: id, changing: TodoChanges(hasExpense: false))

        let after = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertNil(after.category, "关掉花销后不能留下「没有花销却有分类」的脏数据")
        XCTAssertNil(after.account)
    }

    func testCreateRejectsEmptyAndOverlongTitle() throws {
        let sut = try makeSUT()

        XCTAssertThrowsError(try sut.service.create(TodoDraft(title: "   "))) { error in
            XCTAssertEqual(error as? TodoError, .titleEmpty)
        }
        let long = String(repeating: "长", count: TodoService.titleLimit + 1)
        XCTAssertThrowsError(try sut.service.create(TodoDraft(title: long))) { error in
            XCTAssertEqual(error as? TodoError, .titleTooLong)
        }
    }

    func testCreateTrimsTitle() throws {
        let sut = try makeSUT()
        let id = try sut.service.create(TodoDraft(title: "  写周报\n "))

        let todo = try XCTUnwrap(try sut.service.todo(id: id))
        XCTAssertEqual(todo.title, "写周报")
    }

    func testOpenTodosExcludeCompletedOnes() throws {
        let sut = try makeSUT()
        let first = try sut.service.create(TodoDraft(title: "未完成", dueDay: 20261120))
        let second = try sut.service.create(TodoDraft(title: "已完成", dueDay: 20261121))
        try sut.service.complete(id: second, at: now)

        let open = try sut.service.openTodos()
        XCTAssertEqual(open.map(\.id), [first], "列表默认只显示未完成")
    }

    // MARK: - 工具

    /// 测试装配体。显式标注 `@MainActor`：它是嵌套在测试类里的独立类型，
    /// 不会自动继承外层类的 actor 隔离，而 `LedgerWriter` / `TodoService` 都是主线程隔离的。
    @MainActor
    private struct SUT {
        let container: ModelContainer
        let writer: LedgerWriter
        let ledger: LedgerService
        let service: TodoService

        func entryCount(includeDeleted: Bool = false) throws -> Int {
            let entries = try writer.fetch(QueryDescriptors.allEntries())
            return includeDeleted ? entries.count : entries.filter { $0.deletedAt == nil }.count
        }

        func liveEntries() throws -> [LedgerEntry] {
            try writer.fetch(QueryDescriptors.allEntries()).filter { $0.deletedAt == nil }
        }

        /// 建一条带花销的待办、完成、并确认记账，返回待办 id。
        func completedTodoWithEntry(amount: Int64) throws -> UUID {
            let id = try service.create(
                TodoDraft(
                    title: "带账待办",
                    dueDay: 20261121,
                    hasExpense: true,
                    hasEstimatedAmount: true,
                    estimatedAmount: amount
                )
            )
            let request = try service.complete(id: id, at: Date(timeIntervalSince1970: 1_795_000_000))
            _ = try service.confirmCompletion(CompletionConfirmation(amountCents: amount), for: request)
            return id
        }
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let ledger = LedgerService(writer: writer)
        let service = TodoService(writer: writer, ledger: ledger)
        return SUT(container: container, writer: writer, ledger: ledger, service: service)
    }
}
