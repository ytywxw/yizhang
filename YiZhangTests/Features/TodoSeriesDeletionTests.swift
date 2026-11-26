//
//  TodoSeriesDeletionTests.swift
//  一账Tests / Features
//
//  T5-B（V1.1 / F-TODO-11「删除此次及以后」）的验收。
//
//  这一半会改已上线行为（待办行的「⋯」菜单），所以除了功能本身，重点钉三件事：
//  ① **原子性**：「删除这一期」的 spawn 与 delete 必须落在同一次 `save()`；
//  ② **撤销复用原 id**：`Todo.id` 没有 `.unique`，换新 UUID 也能插进去，
//     但账目的 `sourceRefID` 与已排通知都会悬空 —— 所以断言的是"同 id + 全字段一致"；
//  ③ **通知跟着库走**：删完 / 撤销完，pending 里的待办 id 必须与库里一致。
//
//  对应收工标准 ⑧⑨⑩⑪⑫⑬⑭。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class TodoSeriesDeletionTests: XCTestCase {

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

    // MARK: - ⑧ 删除此次及以后

    func testDeleteAndStopSeriesRemovesRowAndSpawnsNothing() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)

        let receipt = try sut.environment.todo.deleteAndStopSeries(id: id, at: moment)

        XCTAssertNil(try sut.todo(id: id), "这一期必须消失")
        XCTAssertEqual(try sut.todoCount(), 0, "「此次及以后」绝不能顺手 spawn 下一期")
        XCTAssertNil(receipt.spawnedNextID)
        XCTAssertTrue(receipt.stoppedSeries, "删的是重复待办，凭据要说明终止了一个系列")
        XCTAssertEqual(receipt.snapshot.id, id)
        XCTAssertTrue(receipt.snapshot.isRepeating)
    }

    func testDeleteAndStopSeriesKeepsCompletedHistoryAndItsEntry() throws {
        let sut = try makeSUT()
        // 昨天那一期：已完成、已记账（历史），完成时顺手生成了今天这一期
        let historyID = try sut.create(
            title: "每天喝水",
            dueDay: 20261120,
            hasExpense: true,
            estimatedAmount: 300,
            repeatRule: .daily
        )
        let request = try sut.environment.todo.complete(id: historyID, at: moment)
        _ = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 300),
            for: request
        )
        let current = try XCTUnwrap(try sut.environment.todo.openTodos().first)
        XCTAssertEqual(current.dueDay, 20261121)

        try sut.environment.todo.deleteAndStopSeries(id: current.id, at: moment)

        XCTAssertNil(try sut.todo(id: current.id))
        XCTAssertNotNil(try sut.todo(id: historyID), "已完成的历史记录要保留（弹层正文的承诺）")
        XCTAssertEqual(try sut.liveEntryCount(), 1, "那笔钱确实花出去了，删待办不抹账")
        XCTAssertEqual(try sut.todoCount(), 1)   // 只剩昨天那条历史
    }

    func testDeleteAndStopSeriesDoesNotComeBackAfterRelaunch() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        try sut.environment.todo.deleteAndStopSeries(id: id, at: moment)

        // 「重启」= 在同一个容器上重新组装一整套环境（数据只可能在 store 里，不可能在内存里）
        let relaunched = try AppEnvironment(container: sut.container)

        XCTAssertTrue(try relaunched.todo.todos().isEmpty, "重启后不该再冒出来")
        XCTAssertNil(try relaunched.todo.todo(id: id))
    }

    func testDeleteAndStopSeriesThrowsForMissingTodo() throws {
        let sut = try makeSUT()
        XCTAssertThrowsError(
            try sut.environment.todo.deleteAndStopSeries(id: UUID(), at: moment)
        ) { error in
            XCTAssertEqual(error as? TodoError, .todoNotFound)
        }
    }

    // MARK: - ⑨ 删除这一期

    func testDeleteCurrentOccurrenceSpawnsNextWithAdvancedDueDay() throws {
        let sut = try makeSUT()
        let id = try sut.create(
            title: "每天喝水",
            note: "8 杯",
            dueDay: 20261121,
            dueTimeMinutes: 540,
            repeatRule: .daily
        )

        let receipt = try sut.environment.todo.deleteCurrentOccurrence(id: id, at: moment)

        XCTAssertNil(try sut.todo(id: id), "这一期要消失")
        let nextID = try XCTUnwrap(receipt.spawnedNextID, "「删除这一期」必须补上下一期，否则系列静默消失")
        let next = try XCTUnwrap(try sut.todo(id: nextID))
        XCTAssertEqual(next.dueDay, 20261122, "每天重复：下一期 = 原截止日 + 1 天")
        XCTAssertEqual(next.title, "每天喝水")
        XCTAssertEqual(next.note, "8 杯")
        XCTAssertEqual(next.dueTimeMinutes, 540)
        XCTAssertEqual(next.repeatRule, .daily)
        XCTAssertEqual(next.status, .open)
        XCTAssertNil(next.completedAt)
        XCTAssertTrue(next.isOpen)
        XCTAssertEqual(try sut.todoCount(), 1, "一次删除只该留下一行")
    }

    func testDeleteCurrentOccurrenceSpawnsNothingWhenNotRepeating() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "交电费", dueDay: 20261121)

        let receipt = try sut.environment.todo.deleteCurrentOccurrence(id: id, at: moment)

        XCTAssertNil(receipt.spawnedNextID, "不重复的待办没有「下一期」")
        XCTAssertFalse(receipt.stoppedSeries)
        XCTAssertEqual(try sut.todoCount(), 0)
    }

    func testDeleteCurrentOccurrenceOnCompletedRowSpawnsNothing() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        // 完成时已经生成过下一期，再 spawn 一次会凭空多出一行
        try sut.environment.todo.complete(id: id, at: moment)
        XCTAssertEqual(try sut.todoCount(), 2, "完成时生成了下一期")

        let receipt = try sut.environment.todo.deleteCurrentOccurrence(id: id, at: moment)

        XCTAssertNil(receipt.spawnedNextID, "已完成的那条不能再 spawn")
        XCTAssertEqual(try sut.todoCount(), 1, "只剩完成时生成的那一期")
    }

    // MARK: - ⑫ 撤销

    func testUndoRestoresSameIDAndEveryField() throws {
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
        let receipt = try sut.environment.todo.deleteAndStopSeries(id: id, at: moment)

        try sut.environment.todo.undoDeletion(receipt)

        let restored = try XCTUnwrap(try sut.todo(id: id), "撤销必须复用原 id（账目的 sourceRefID 指向它）")
        // TODO: 给 Todo 加字段必须来这里加一行（同步 TodoSnapshot + TodoService.restore(_:from:)）。
        XCTAssertEqual(restored.id, receipt.snapshot.id)
        XCTAssertEqual(
            TodoSnapshot(todo: restored), receipt.snapshot,
            "撤销的正确性标准是逐字段一致，漏一个字段就是悄悄丢数据"
        )
    }

    func testUndoRestoresCompletedOccurrenceWithLinkedEntry() throws {
        let sut = try makeSUT()
        let id = try sut.create(
            title: "午饭",
            dueDay: 20261121,
            hasExpense: true,
            estimatedAmount: 2500
        )
        let request = try sut.environment.todo.complete(id: id, at: moment)
        let outcome = try sut.environment.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 2500),
            for: request
        )
        guard case .inserted = outcome else {
            return XCTFail("应当插入一笔账目")
        }
        let receipt = try sut.environment.todo.deleteAndStopSeries(id: id, at: moment)

        try sut.environment.todo.undoDeletion(receipt)

        let restored = try XCTUnwrap(try sut.todo(id: id))
        XCTAssertEqual(TodoSnapshot(todo: restored), receipt.snapshot, "状态 / completedAt / linkedEntryID 都要回来")
        XCTAssertEqual(restored.status, .done)
        XCTAssertNotNil(restored.linkedEntryID, "关联账目要重新挂回来")
        XCTAssertNotNil(restored.linkedEntry)
        XCTAssertEqual(try sut.liveEntryCount(), 1, "撤销待办不该产生第二笔账")
    }

    func testUndoOfCurrentOccurrenceRemovesSpawnedNext() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let receipt = try sut.environment.todo.deleteCurrentOccurrence(id: id, at: moment)
        let nextID = try XCTUnwrap(receipt.spawnedNextID)

        try sut.environment.todo.undoDeletion(receipt)

        XCTAssertNotNil(try sut.todo(id: id), "原行回来了")
        XCTAssertNil(try sut.todo(id: nextID), "顺带生成的那一期必须被清掉（否则撤销后有两行）")
        XCTAssertEqual(try sut.todoCount(), 1, "撤销「删除这一期」后不能留下两行")
    }

    func testUndoTwiceKeepsExactlyOneRow() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let receipt = try sut.environment.todo.deleteAndStopSeries(id: id, at: moment)

        try sut.environment.todo.undoDeletion(receipt)
        try sut.environment.todo.undoDeletion(receipt)

        XCTAssertEqual(try sut.todoCount(), 1, "连点两次撤销不能插出两条同 id 的待办")
        XCTAssertEqual(try sut.todo(id: id)?.title, "每天喝水")
    }

    // MARK: - ⑪ 通知跟着库走

    func testPendingNotificationsDropDeletedTodo() async throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let client = RecordingNotificationClient(permission: .authorized)
        let notifications = NotificationService(client: client)

        await reschedule(notifications, in: sut.environment)
        let beforeDeletion = await client.pendingIdentifiers()
        XCTAssertTrue(
            beforeDeletion.contains(NotificationPlanner.todoDueID(todoID: id)),
            "删之前这条待办应该有提醒"
        )

        try sut.environment.todo.deleteAndStopSeries(id: id, at: moment)
        await reschedule(notifications, in: sut.environment)

        let identifiers = await client.pendingIdentifiers()
        XCTAssertFalse(
            identifiers.contains(NotificationPlanner.todoDueID(todoID: id)),
            "删掉的待办不能留在 pending 里（否则到期日会提醒一件不存在的事）"
        )
        XCTAssertTrue(identifiers.isEmpty)
    }

    func testPendingNotificationsFollowSpawnedOccurrence() async throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let receipt = try sut.environment.todo.deleteCurrentOccurrence(id: id, at: moment)
        let nextID = try XCTUnwrap(receipt.spawnedNextID)
        let client = RecordingNotificationClient(permission: .authorized)
        let notifications = NotificationService(client: client)

        await reschedule(notifications, in: sut.environment)

        let identifiers = await client.pendingIdentifiers()
        XCTAssertFalse(identifiers.contains(NotificationPlanner.todoDueID(todoID: id)), "旧的那一期没了")
        XCTAssertTrue(identifiers.contains(NotificationPlanner.todoDueID(todoID: nextID)), "新的一期要排上")
    }

    // MARK: - 行模型：菜单分支的依据（⑩）

    func testRowModelMarksRepeatingTodos() throws {
        let sut = try makeSUT()
        let repeating = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        _ = try sut.create(title: "交电费", dueDay: 20261121)

        let viewModel = TodoListViewModel(today: today)
        viewModel.attach(sut.environment)
        let rows = viewModel.groups.flatMap(\.rows)

        let repeatingRow = try XCTUnwrap(rows.first { $0.id == repeating })
        XCTAssertTrue(repeatingRow.isRepeating, "菜单据此出「删除这一期 / 删除此次及以后」")
        XCTAssertFalse(repeatingRow.isDone)

        let plainRow = try XCTUnwrap(rows.first { $0.title == "交电费" })
        XCTAssertFalse(plainRow.isRepeating, "不重复的待办只出「删除」")
    }

    func testRowModelKeepsRepeatingFlagOnCompletedRows() throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        try sut.environment.todo.complete(id: id, at: moment)

        let viewModel = TodoListViewModel(today: today)
        viewModel.attach(sut.environment)
        let row = try XCTUnwrap(viewModel.groups.first { $0.kind == .done }?.rows.first)

        XCTAssertTrue(row.isDone)
        XCTAssertTrue(row.isRepeating, "图：已完成 + 重复 → 菜单只有「删除这条记录」，靠 isDone 判断，不走这一支")
    }

    func testRowModelDefaultIsNotRepeating() {
        // 文档式断言：`isRepeating` 是 `var` + 默认值，旧调用点（含 Preview）不用改
        let row = TodoRowModel(
            id: UUID(),
            title: "交电费",
            dueText: nil,
            detailText: nil,
            dueDay: 0,
            hasDueDate: false,
            isDone: false,
            isOverdue: false,
            hasExpense: false,
            priority: .none,
            isFromSubscription: false,
            hasLinkedEntry: false,
            linkedEntryDeleted: false
        )
        XCTAssertFalse(row.isRepeating)
    }

    // MARK: - ViewModel：3 秒撤销窗口

    func testViewModelDeleteAndStopSeriesOffersUndo() async throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let viewModel = sut.listViewModel(today: today)

        let deleted = await viewModel.deleteAndStopSeries(id: id)
        let feedback = try XCTUnwrap(deleted)

        XCTAssertTrue(feedback.canUndo, "给了撤销入口才谈得上「3 秒撤销」")
        XCTAssertEqual(feedback.message, "已删除，以后不会再重复")
        XCTAssertTrue(viewModel.canUndoDeletion)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testViewModelUndoRestoresTheRowInTheList() async throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let viewModel = sut.listViewModel(today: today)
        _ = await viewModel.deleteAndStopSeries(id: id)
        XCTAssertTrue(viewModel.groups.isEmpty, "删完列表里就没了")

        let message = await viewModel.undoDeletion()

        XCTAssertEqual(message, "已撤销，重复设置也回来了")
        let rows = viewModel.groups.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.id), [id], "撤销后列表要立刻恢复，且是同一条")
        XCTAssertFalse(viewModel.canUndoDeletion, "撤销只能用一次")
    }

    func testViewModelUndoIsRejectedAfterWindow() async throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let viewModel = sut.listViewModel(today: today)
        _ = await viewModel.deleteAndStopSeries(id: id)

        let late = Date().addingTimeInterval(TodoListViewModel.undoWindow + 1)
        let message = await viewModel.undoDeletion(now: late)

        XCTAssertNil(message, "超时后撤销入口失效（⑭）")
        XCTAssertNil(try sut.todo(id: id), "超时撤销不能悄悄生效")
        XCTAssertNil(viewModel.undoReceipt)
        XCTAssertNil(viewModel.undoExpiresAt)
    }

    func testSecondDeletionReplacesTheUndoReceipt() async throws {
        let sut = try makeSUT()
        let first = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let second = try sut.create(title: "每天拉伸", dueDay: 20261121, repeatRule: .daily)
        let viewModel = sut.listViewModel(today: today)

        _ = await viewModel.deleteAndStopSeries(id: first)
        let firstExpiry = try XCTUnwrap(viewModel.undoExpiresAt)
        _ = await viewModel.deleteAndStopSeries(id: second)
        let secondExpiry = try XCTUnwrap(viewModel.undoExpiresAt)

        XCTAssertEqual(viewModel.undoReceipt?.snapshot.id, second, "撤销只对最近一次删除有效")
        XCTAssertGreaterThanOrEqual(secondExpiry, firstExpiry)
        // 旧的计时器被 cancel 掉，才不会在 3 秒后把第二次的凭据一起清掉
        _ = await viewModel.undoDeletion()
        XCTAssertNotNil(try sut.todo(id: second), "最近一条回来了")
        XCTAssertNil(try sut.todo(id: first), "更早那条不会跟着回来")
    }

    func testViewModelDeleteCurrentOccurrenceKeepsSeriesAlive() async throws {
        let sut = try makeSUT()
        let id = try sut.create(title: "每天喝水", dueDay: 20261121, repeatRule: .daily)
        let viewModel = sut.listViewModel(today: today)

        let skipped = await viewModel.deleteCurrentOccurrence(id: id)
        let feedback = try XCTUnwrap(skipped)

        XCTAssertTrue(feedback.canUndo)
        let rows = viewModel.groups.flatMap(\.rows)
        XCTAssertEqual(rows.count, 1, "这一期没了、下一期顶上")
        XCTAssertNotEqual(rows.first?.id, id)
        XCTAssertEqual(try sut.todoCount(), 1)
    }

    // MARK: - 工具

    /// 用只读上下文里的未完成待办喂给真实的 `NotificationPlanner`。
    private func reschedule(_ service: NotificationService, in environment: AppEnvironment) async {
        let todos = (try? environment.todo.openTodos()) ?? []
        let seeds = todos.map {
            NotificationPlanner.TodoSeed(
                id: $0.id,
                title: $0.displayTitle,
                dueDay: $0.dueDay,
                dueTimeMinutes: $0.dueTimeMinutes,
                isDone: $0.isDone
            )
        }
        await service.rescheduleAll(subscriptions: [], todos: seeds, today: today)
    }

    @MainActor
    private struct SUT {
        let container: ModelContainer
        let environment: AppEnvironment

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

// MARK: - 通知客户端假件

/// 记录 pending 的假通知中心（`NotificationServiceTests` 里那份是 fileprivate，
/// 这里要独立一份，避免两个测试文件互相依赖）。
private final class RecordingNotificationClient: NotificationCenterClient {

    private var status: NotificationPermission
    private(set) var pending: [PendingNotification] = []

    init(permission: NotificationPermission) {
        self.status = permission
    }

    func permissionStatus() async -> NotificationPermission { status }

    func requestPermission() async -> NotificationPermission { status }

    func replacePending(_ requests: [PendingNotification]) async {
        pending = requests
    }

    func pendingIdentifiers() async -> [String] {
        pending.map(\.id)
    }
}
