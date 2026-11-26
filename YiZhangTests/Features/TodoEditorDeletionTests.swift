//
//  TodoEditorDeletionTests.swift
//  一账Tests / Features
//
//  详情页（`TodoEditorView`）删除项的规格验收。
//
//  ## 这一页原先的问题（不是"没确认"，是"说法与做法不一致"）
//
//  弹层问的是通用的「删除这条待办？」「待办本身会被移除。已经记过的账目会保留。」
//  底层走的却是 `TodoService.delete(id:)` —— 硬删、不 spawn。对**重复待办**而言，
//  这个效果精确等于「删除此次及以后」：用户以为只是删了一条待办，
//  实际上整个系列就此结束，而且这条路径没有撤销（列表页同语义操作有 3 秒撤销）。
//
//  ## 本文件钉的三件事
//
//  ① **说它实际在做的事**：删一条记录 / 跳过一期 / 终止系列，三条路径各自的
//     凭据与文案要对得上（`stoppedSeries`、`spawnedNextID`、Toast 文案）；
//  ② **撤销靠回传凭据**：详情页删完就 dismiss，撤销窗口只能由列表页接管 ——
//     所以 `adoptUndo` 必须能把凭据接进同一个窗口，且覆盖前一个窗口；
//  ③ **不 spawn / 不抹账**：删待办永远不动已经花出去的那笔钱（与列表页同口径）。
//
//  ⚠️ 本文件只测 ViewModel 层，不测 SwiftUI 弹层本身：
//  弹层的分支选择在 `TodoEditorView` 里由 `isDone` / `isRepeating` 决定，
//  那两个判据在下面都有直接断言（`XCTAssertTrue(editor.isDone)` 等），
//  测到"判据正确 + 方法语义正确"就够了，去驱动 `confirmationDialog` 只会换来 flaky。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class TodoEditorDeletionTests: XCTestCase {

    /// 固定"今天"：2026-11-21。
    private let today = DateOnly(key: 20261121)

    /// 固定时刻（与 `today` 同一天，避免踩到"未来日期"的校验）。
    private var moment: Date {
        DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: .current,
            year: 2026,
            month: 11,
            day: 21,
            hour: 10,
            minute: 30
        ).date ?? Date(timeIntervalSince1970: 1_795_000_000)
    }

    // MARK: - ① 未完成 + 重复 → 「删除此次及以后」

    func testStopSeriesFromEditorDeletesRowSpawnsNothingAndOffersReceipt() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let editor = sut.editor(id: id, today: today)
        XCTAssertTrue(editor.isRepeating, "`.daily` 必须被判成重复")
        XCTAssertFalse(editor.isDone)

        let result = try XCTUnwrap(editor.deleteAndStopSeries(), "删除失败会返回 nil 并写 errorMessage")

        guard case .deleted(let message, let receipt) = result else {
            return XCTFail("删除路径必须返回 .deleted，而不是 .saved")
        }
        XCTAssertEqual(message, "已停止重复")
        XCTAssertNil(try sut.todo(id: id), "这一期必须消失")
        XCTAssertEqual(try sut.todoCount(), 0, "「此次及以后」绝不能顺手 spawn 下一期")
        XCTAssertTrue(receipt.stoppedSeries, "删的是重复待办，凭据要说明终止了一个系列")
        XCTAssertNil(receipt.spawnedNextID, "终止系列的凭据里 `spawnedNextID` 恒为 nil")
        XCTAssertNil(editor.errorMessage)
    }

    // MARK: - ② 未完成 + 重复 → 「删除这一期」

    func testSkipOccurrenceFromEditorKeepsSeriesAlive() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let editor = sut.editor(id: id, today: today)

        let result = try XCTUnwrap(editor.deleteCurrentOccurrence())

        guard case .deleted(let message, let receipt) = result else {
            return XCTFail("删除路径必须返回 .deleted")
        }
        XCTAssertEqual(message, "已跳过这一期")
        XCTAssertNil(try sut.todo(id: id), "这一期没了")

        let nextID = try XCTUnwrap(receipt.spawnedNextID, "「删除这一期」必须生成下一期")
        let next = try XCTUnwrap(try sut.todo(id: nextID))
        XCTAssertEqual(next.dueDay, 20261122, "每 1 天的周期，下一期就是次日")
        XCTAssertEqual(next.title, "每天喝水", "下一期继承标题")
        XCTAssertEqual(next.repeatRule, .daily, "下一期仍然重复（系列还活着）")
        XCTAssertEqual(next.status, .open)
        XCTAssertEqual(try sut.todoCount(), 1, "只剩下一期，不能留下两行")
    }

    // MARK: - ③ 未完成 + 非重复 → 普通删除

    func testNonRepeatingDeleteFromEditorNeverSaysSeriesStopped() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "取快递", dueDay: 20261121)
        let editor = sut.editor(id: id, today: today)
        XCTAssertFalse(editor.isRepeating, "没设重复规则就不是重复待办")

        let result = try XCTUnwrap(editor.deleteAndStopSeries())

        guard case .deleted(let message, let receipt) = result else {
            return XCTFail("删除路径必须返回 .deleted")
        }
        // 非重复也走 `deleteAndStopSeries`（详情页不留第二条"裸删"通路），
        // 但文案不能说成「已停止重复」—— 根本没有系列可停。
        XCTAssertEqual(message, "已删除待办")
        XCTAssertFalse(receipt.stoppedSeries)
        XCTAssertNil(receipt.spawnedNextID)
        XCTAssertNil(try sut.todo(id: id))
        XCTAssertEqual(try sut.todoCount(), 0)
    }

    // MARK: - ④ 已完成 + 重复 → 删的是「一条记录」

    func testDeletingCompletedRepeatingRecordDoesNotStopSeriesOrDropEntry() throws {
        let sut = try makeSUT()
        let id = try sut.create(
            title: "每天喝水",
            dueDay: 20261121,
            hasExpense: true,
            estimatedAmount: 300,
            repeatRule: .daily
        )
        let request = try sut.environment.todo.complete(id: id, at: moment)
        let outcome = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 300),
            for: request
        )
        guard case .inserted = outcome else {
            return XCTFail("应当插入一笔账目")
        }
        // `complete` 已经 spawn 了下一期 → 库里两行（这是前置条件，不是被测行为）
        XCTAssertEqual(try sut.todoCount(), 2)

        let editor = sut.editor(id: id, today: today)
        XCTAssertTrue(editor.isDone, "已完成状态必须被读出来，弹层靠它选分支")
        XCTAssertTrue(editor.isRepeating)

        let result = try XCTUnwrap(editor.deleteAndStopSeries())

        guard case .deleted(let message, let receipt) = result else {
            return XCTFail("删除路径必须返回 .deleted")
        }
        // 关键断言：这条待办的 `stoppedSeries` 也是 true（它确实属于重复系列），
        // 但下一期在 complete 时就已经存在了 —— 删掉这条历史记录**没有**停掉系列。
        // 文案必须说「已删除记录」，说成「已停止重复」就是在骗用户。
        XCTAssertEqual(message, "已删除记录")
        XCTAssertTrue(receipt.stoppedSeries, "凭据如实反映它属于重复系列")
        XCTAssertNil(receipt.spawnedNextID, "已完成的那条不该再 spawn")

        XCTAssertNil(try sut.todo(id: id), "这条历史记录被删掉")
        XCTAssertEqual(try sut.todoCount(), 1, "下一期留着（系列没停）")
        XCTAssertEqual(try sut.liveEntryCount(), 1, "那笔钱确实花出去了，删待办不抹账")
    }

    // MARK: - ⑤ adoptUndo：凭据回传后接进列表页的撤销窗口

    func testAdoptUndoRestoresSameIDAndEveryField() async throws {
        let sut = try makeSUT()
        let id = try sut.create(
            title: "每天喝水",
            note: "8 杯",
            dueDay: 20261121,
            dueTimeMinutes: 540,
            hasExpense: true,
            estimatedAmount: 300,
            priority: .high,
            repeatRule: .daily,
            reminderDay: 20261121,
            reminderMinutes: 480,
            categoryID: try sut.categoryID(named: "餐饮"),
            accountID: try sut.accountID(named: "微信")
        )
        let editor = sut.editor(id: id, today: today)
        let listViewModel = sut.listViewModel(today: today)
        XCTAssertFalse(listViewModel.canUndoDeletion, "删之前没有可撤销的东西")

        guard case .deleted(let message, let receipt) = try XCTUnwrap(editor.deleteAndStopSeries()) else {
            return XCTFail("删除路径必须返回 .deleted")
        }
        XCTAssertNil(try sut.todo(id: id), "删除已经生效")
        let feedback = listViewModel.adoptUndo(receipt, message: message)

        XCTAssertTrue(feedback.canUndo, "回传凭据后必须立刻可撤销")
        XCTAssertEqual(feedback.message, message, "文案由编辑器决定，列表页不改写")
        XCTAssertTrue(listViewModel.canUndoDeletion, "窗口注册必须同步完成（dismiss 之前）")

        let undoMessage = await listViewModel.undoDeletion()

        XCTAssertEqual(undoMessage, "已撤销，重复设置也回来了")
        let restored = try XCTUnwrap(try sut.todo(id: id), "撤销必须复用原 id（账目的 sourceRefID 指向它）")
        // TODO: 给 Todo 加字段必须来这里加一行（同步 TodoSnapshot + TodoService.restore(_:from:)）。
        XCTAssertEqual(
            TodoSnapshot(todo: restored), receipt.snapshot,
            "撤销的正确性标准是逐字段一致，漏一个字段就是悄悄丢数据"
        )
        XCTAssertEqual(try sut.todoCount(), 1)
        XCTAssertFalse(listViewModel.canUndoDeletion, "撤销只能用一次")
    }

    // MARK: - ⑥ adoptUndo 覆盖前一个窗口

    func testAdoptUndoReplacesThePreviousWindow() async throws {
        let sut = try makeSUT()
        let first = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let second = try sut.create(title: "每天拉伸", dueDay: 20261121, repeatRule: .daily)
        let listViewModel = sut.listViewModel(today: today)

        guard case .deleted(let firstMessage, let firstReceipt) =
            try XCTUnwrap(sut.editor(id: first, today: today).deleteAndStopSeries()) else {
            return XCTFail("第一次删除必须返回 .deleted")
        }
        listViewModel.adoptUndo(firstReceipt, message: firstMessage)
        let firstExpiry = try XCTUnwrap(listViewModel.undoExpiresAt)

        guard case .deleted(let secondMessage, let secondReceipt) =
            try XCTUnwrap(sut.editor(id: second, today: today).deleteAndStopSeries()) else {
            return XCTFail("第二次删除必须返回 .deleted")
        }
        listViewModel.adoptUndo(secondReceipt, message: secondMessage)
        let secondExpiry = try XCTUnwrap(listViewModel.undoExpiresAt)

        XCTAssertEqual(listViewModel.undoReceipt?.snapshot.id, second, "撤销只对最近一次删除有效")
        // 这里必须是**严格大于**，不能写 `>=`：如果 `adoptUndo` 没有重开窗口，而是沿用
        // 上一个截止时刻，那么 `secondExpiry` 会和 `firstExpiry` 一模一样 —— `>=` 照样绿，
        // 断言文字说的「重新起算」却根本没被验证。两次删除之间隔着一整轮
        // fetch + delete + save，`Date()` 不可能相同，所以 `>` 稳定成立。
        XCTAssertGreaterThan(secondExpiry, firstExpiry, "窗口重新起算，不是沿用旧的截止时刻")

        _ = await listViewModel.undoDeletion()

        XCTAssertNotNil(try sut.todo(id: second), "最近一条回来了")
        XCTAssertNil(try sut.todo(id: first), "更早那条不会跟着回来")
        XCTAssertEqual(try sut.todoCount(), 1, "两次撤销不该留下两行")
    }

    // MARK: - SUT

    @MainActor
    private struct SUT {
        let container: ModelContainer
        let environment: AppEnvironment

        /// 详情页编辑器（`mode == .edit`），已 `attach`。
        func editor(id: UUID, today: DateOnly) -> TodoEditorViewModel {
            let viewModel = TodoEditorViewModel(mode: .edit(id), today: today)
            viewModel.attach(environment)
            return viewModel
        }

        /// 列表页状态机，已 `attach`（撤销窗口的宿主）。
        func listViewModel(today: DateOnly) -> TodoListViewModel {
            let viewModel = TodoListViewModel(today: today)
            viewModel.attach(environment)
            return viewModel
        }

        @discardableResult
        func create(
            title: String,
            note: String = "",
            dueDay: Int32 = 0,
            dueTimeMinutes: Int32 = -1,
            hasExpense: Bool = false,
            estimatedAmount: Int64 = 0,
            priority: TodoPriority = .none,
            repeatRule: RepeatRule = .none,
            repeatInterval: Int = 1,
            reminderDay: Int32 = 0,
            reminderMinutes: Int32 = -1,
            categoryID: UUID? = nil,
            accountID: UUID? = nil
        ) throws -> UUID {
            try environment.todo.create(
                TodoDraft(
                    title: title,
                    note: note,
                    dueDay: dueDay,
                    dueTimeMinutes: dueTimeMinutes,
                    hasExpense: hasExpense,
                    hasEstimatedAmount: estimatedAmount > 0,
                    estimatedAmount: estimatedAmount,
                    priority: priority,
                    repeatRule: repeatRule,
                    repeatInterval: repeatInterval,
                    categoryID: categoryID,
                    accountID: accountID,
                    reminderDay: reminderDay,
                    reminderMinutes: reminderMinutes
                )
            )
        }

        func todo(id: UUID) throws -> Todo? {
            try environment.todo.todo(id: id)
        }

        func todoCount() throws -> Int {
            try environment.todo.todos().count
        }

        func liveEntryCount() throws -> Int {
            try environment.readContext.fetch(QueryDescriptors.allEntries())
                .filter { $0.deletedAt == nil }
                .count
        }

        func categoryID(named name: String) throws -> UUID {
            let categories = try environment.readContext.fetch(
                QueryDescriptors.categories(of: .expense)
            )
            guard let match = categories.first(where: { $0.name == name }) else {
                throw XCTSkip("种子数据里没有分类「\(name)」")
            }
            return match.id
        }

        func accountID(named name: String) throws -> UUID {
            let accounts = try environment.readContext.fetch(QueryDescriptors.accounts())
            guard let match = accounts.first(where: { $0.name == name }) else {
                throw XCTSkip("种子数据里没有账户「\(name)」")
            }
            return match.id
        }
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        return SUT(container: container, environment: environment)
    }
}
