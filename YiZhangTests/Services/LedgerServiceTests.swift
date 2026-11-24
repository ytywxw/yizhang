//
//  LedgerServiceTests.swift
//  一账Tests / Services
//
//  验证 T06：业务校验 + 月度汇总 + 软删撤销 + "编辑不改来源"。
//  这些是用户能直接感知的错误面（"为什么保存不了"），所以逐条断言。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class LedgerServiceTests: XCTestCase {

    /// 装好种子（19 分类 / 5 账户）后的服务。
    private func makeService() throws -> (LedgerService, LedgerWriter, ModelContainer) {
        let container = try ModelContainerFactory.make(inMemory: true)
        _ = try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let service = LedgerService(writer: writer)
        return (service, writer, container)
    }

    private func firstExpenseCategoryID(_ writer: LedgerWriter) throws -> UUID {
        let categories = try writer.fetch(QueryDescriptors.categories(of: .expense))
        return try XCTUnwrap(categories.first?.id)
    }

    private func firstAccountID(_ writer: LedgerWriter) throws -> UUID {
        let accounts = try writer.fetch(QueryDescriptors.accounts())
        return try XCTUnwrap(accounts.first?.id)
    }

    // MARK: - 校验

    func testCreateRejectsZeroAmount() async throws {
        let (service, writer, _) = try makeService()
        var draft = EntryDraft(amount: 0, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)

        XCTAssertThrowsError(try service.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .amountNotPositive)
        }
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 0, "校验失败不得落库")
    }

    func testCreateRejectsExpenseWithoutCategory() async throws {
        let (service, writer, _) = try makeService()
        var draft = EntryDraft(amount: 1200, occurredDay: DateOnly(Date()).key)
        draft.accountID = try firstAccountID(writer)

        XCTAssertThrowsError(try service.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .missingCategory)
        }
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 0)
    }

    func testCreateRejectsTransferToSameAccount() async throws {
        let (service, writer, _) = try makeService()
        let accountID = try firstAccountID(writer)
        var draft = EntryDraft(typeRaw: EntryType.transfer.raw, amount: 5000, occurredDay: DateOnly(Date()).key)
        draft.accountID = accountID
        draft.toAccountID = accountID

        XCTAssertThrowsError(try service.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .sameTransferAccount)
        }
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 0)
    }

    func testCreateRejectsFutureDate() async throws {
        let (service, writer, _) = try makeService()
        let tomorrow = DateOnly(Date()).adding(days: 1)
        var draft = EntryDraft(amount: 1200, occurredDay: tomorrow.key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)

        XCTAssertThrowsError(try service.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .futureDate)
        }
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 0)
    }

    func testCreateRejectsUnknownAccount() async throws {
        let (service, writer, _) = try makeService()
        var draft = EntryDraft(amount: 1200, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = UUID()

        XCTAssertThrowsError(try service.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .missingAccount)
        }
    }

    func testCreateRejectsTooLongNote() async throws {
        let (service, writer, _) = try makeService()
        var draft = EntryDraft(amount: 1200, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)
        draft.note = String(repeating: "字", count: LedgerService.noteLimit + 1)

        XCTAssertThrowsError(try service.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .noteTooLong)
        }
    }

    // MARK: - 创建与统计

    func testCreateThenMonthSummaryIsCorrect() async throws {
        let (service, writer, _) = try makeService()
        let today = DateOnly(Date())
        let categoryID = try firstExpenseCategoryID(writer)
        let accountID = try firstAccountID(writer)

        var expense = EntryDraft(amount: 2800, occurredDay: today.key)
        expense.categoryID = categoryID
        expense.accountID = accountID
        try service.create(expense)

        var expense2 = EntryDraft(amount: 1200, occurredDay: today.key)
        expense2.categoryID = categoryID
        expense2.accountID = accountID
        try service.create(expense2)

        var income = EntryDraft(typeRaw: EntryType.income.raw, amount: 500_000, occurredDay: today.key)
        income.categoryID = try XCTUnwrap(writer.fetch(QueryDescriptors.categories(of: .income)).first?.id)
        income.accountID = accountID
        try service.create(income)

        // 转账不计入收支
        var transfer = EntryDraft(typeRaw: EntryType.transfer.raw, amount: 10_000, occurredDay: today.key)
        transfer.accountID = accountID
        transfer.toAccountID = try XCTUnwrap(
            writer.fetch(QueryDescriptors.accounts()).dropFirst().first?.id
        )
        try service.create(transfer)

        let summary = try service.monthSummary(monthKey: today.monthKey)
        XCTAssertEqual(summary.expense, Money(cents: 4000))
        XCTAssertEqual(summary.income, Money(cents: 500_000))
        XCTAssertEqual(summary.balance, Money(cents: 496_000))
        XCTAssertFalse(summary.isEmpty)

        XCTAssertEqual(try service.entries(in: today.monthKey).count, 4)
    }

    func testMonthSummaryOfEmptyMonthIsZero() async throws {
        let (service, _, _) = try makeService()
        let summary = try service.monthSummary(monthKey: 202001)
        XCTAssertEqual(summary.expense, .zero)
        XCTAssertEqual(summary.income, .zero)
        XCTAssertTrue(summary.isEmpty)
    }

    func testCreateFillsUniqueKeyForTodoSource() async throws {
        let (service, writer, _) = try makeService()
        let todoID = UUID()
        var draft = EntryDraft(amount: 2000, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)
        draft.sourceRaw = EntrySource.todo.raw
        draft.sourceRefID = todoID

        let outcome = try service.create(draft)
        let entryID = try XCTUnwrap(outcome.entryID)
        let entry = try XCTUnwrap(try writer.entry(id: entryID))
        XCTAssertEqual(entry.sourceCycleUniqueKey, "todo|\(todoID.uuidString)")

        // 同一条待办再创建一次（模拟重复点击）→ 幂等命中
        let repeatOutcome = try service.create(draft)
        XCTAssertFalse(repeatOutcome.wasInserted)
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 1)
    }

    func testCreateFillsUniqueKeyForSubscriptionSource() async throws {
        let (service, writer, _) = try makeService()
        let subscriptionID = UUID()
        var draft = EntryDraft(amount: 2500, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = subscriptionID
        draft.sourceCycleKey = "2025-11"

        let entryID = try XCTUnwrap(try service.create(draft).entryID)
        let entry = try XCTUnwrap(try writer.entry(id: entryID))
        XCTAssertEqual(
            entry.sourceCycleUniqueKey,
            SubscriptionSnapshot.makeUniqueKey(subscriptionID: subscriptionID, cycleKey: "2025-11"),
            "订阅幂等键必须复用 SubscriptionSnapshot.makeUniqueKey"
        )
    }

    // MARK: - 删除与撤销

    func testDeleteThenUndoRestoresCount() async throws {
        let (service, writer, _) = try makeService()
        let today = DateOnly(Date())
        var draft = EntryDraft(amount: 2800, occurredDay: today.key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)

        let entryID = try XCTUnwrap(try service.create(draft).entryID)
        XCTAssertEqual(try service.entries(in: today.monthKey).count, 1)

        let deletedToken = await service.delete(id: entryID)
        let token = try XCTUnwrap(deletedToken)
        XCTAssertEqual(token.entryID, entryID)
        XCTAssertEqual(try service.entries(in: today.monthKey).count, 0, "软删后不再出现在列表与统计里")
        XCTAssertEqual(try service.monthSummary(monthKey: today.monthKey).expense, .zero)

        XCTAssertTrue(service.undoDelete(token))
        XCTAssertEqual(try service.entries(in: today.monthKey).count, 1, "撤销后总数恢复")
        XCTAssertNil(try writer.entry(id: entryID)?.deletedAt)
    }

    func testUndoDeleteOnHardDeletedEntryReturnsFalse() async throws {
        let (service, writer, _) = try makeService()
        var draft = EntryDraft(amount: 2800, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)

        let entryID = try XCTUnwrap(try service.create(draft).entryID)
        let deletedToken = await service.delete(id: entryID)
        let token = try XCTUnwrap(deletedToken)
        _ = try writer.hardDelete(id: entryID)

        XCTAssertFalse(service.undoDelete(token), "凭据失效时静默失败，不弹错误")
    }

    func testDeleteMissingEntryReturnsNil() async throws {
        let (service, _, _) = try makeService()
        let token = await service.delete(id: UUID())
        XCTAssertNil(token)
    }

    // MARK: - 编辑

    func testUpdateAmountKeepsSource() async throws {
        let (service, writer, _) = try makeService()
        let todoID = UUID()
        var draft = EntryDraft(amount: 2000, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)
        draft.sourceRaw = EntrySource.todo.raw
        draft.sourceRefID = todoID

        let entryID = try XCTUnwrap(try service.create(draft).entryID)

        let snapshot = try service.update(id: entryID, changing: EntryChanges(amount: 3200, note: "改了金额"))

        XCTAssertEqual(snapshot.amount, 3200)
        XCTAssertEqual(snapshot.note, "改了金额")
        XCTAssertEqual(snapshot.sourceRaw, EntrySource.todo.raw, "R-EDIT-1/2：编辑不得改写来源")
        XCTAssertEqual(snapshot.sourceRefID, todoID)
        XCTAssertEqual(
            snapshot.sourceCycleUniqueKey,
            "todo|\(todoID.uuidString)",
            "幂等键也不能因为编辑而丢失"
        )
    }

    func testUpdateRejectsInvalidMergedState() async throws {
        let (service, writer, _) = try makeService()
        var draft = EntryDraft(amount: 2000, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try firstExpenseCategoryID(writer)
        draft.accountID = try firstAccountID(writer)

        let entryID = try XCTUnwrap(try service.create(draft).entryID)

        XCTAssertThrowsError(try service.update(id: entryID, changing: EntryChanges(amount: 0))) { error in
            XCTAssertEqual(error as? LedgerError, .amountNotPositive)
        }
        XCTAssertThrowsError(
            try service.update(id: entryID, changing: EntryChanges(occurredDay: DateOnly(Date()).adding(days: 3).key))
        ) { error in
            XCTAssertEqual(error as? LedgerError, .futureDate)
        }

        // 失败的编辑不得改动原账目
        XCTAssertEqual(try writer.entry(id: entryID)?.amount, 2000)
    }

    func testUpdateMissingEntryThrows() async throws {
        let (service, _, _) = try makeService()
        XCTAssertThrowsError(try service.update(id: UUID(), changing: EntryChanges(amount: 100))) { error in
            XCTAssertEqual(error as? LedgerError, .entryNotFound)
        }
    }

    // MARK: - 账户余额

    func testAccountBalanceUsesCalculator() async throws {
        let (service, writer, _) = try makeService()
        let today = DateOnly(Date())
        let accounts = try writer.fetch(QueryDescriptors.accounts())
        let cash = try XCTUnwrap(accounts.first)
        let card = try XCTUnwrap(accounts.dropFirst().first)

        // 期初余额设为 1000 元
        try writer.update(cash) { account in
            account.initialBalance = 100_000
        }

        var expense = EntryDraft(amount: 20_000, occurredDay: today.key)
        expense.categoryID = try firstExpenseCategoryID(writer)
        expense.accountID = cash.id
        try service.create(expense)

        var transfer = EntryDraft(typeRaw: EntryType.transfer.raw, amount: 10_000, occurredDay: today.key)
        transfer.accountID = cash.id
        transfer.toAccountID = card.id
        try service.create(transfer)

        XCTAssertEqual(try service.accountBalance(accountID: cash.id), Money(cents: 70_000))
    }
}
