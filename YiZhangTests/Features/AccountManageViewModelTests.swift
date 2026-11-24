//
//  AccountManageViewModelTests.swift
//  一账Tests / Features
//
//  T21 账户管理要在**真实容器**上验证，因为它碰的是"删除 / 归档 / 排序"这种会改数据的事：
//  ① 余额是算出来的（R-ACC-1），转账两侧必须各算一次、且不能重复算；
//  ② 有账目时删除**必须降级为归档**（R-ACC-2）——直接删会让历史账目失去账户引用；
//  ③ 归档后账户不能再出现在记账选择器里，但行还在（历史账目要看得到名字）。
//
//  这三条如果只靠 UI 点，回归成本极高（要造账目、点删除、再翻历史），
//  所以在 ViewModel 层钉死。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class AccountManageViewModelTests: XCTestCase {

    private func makeSUT() throws -> (environment: AppEnvironment, viewModel: AccountManageViewModel) {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        let viewModel = AccountManageViewModel()
        viewModel.attach(environment)
        return (environment, viewModel)
    }

    /// 记一笔账（`LedgerService` 要求非转账账目必须有分类，这里统一补上）。
    private func createEntry(
        _ environment: AppEnvironment,
        type: EntryType = .expense,
        amount: Int64,
        accountID: UUID,
        toAccountID: UUID? = nil
    ) throws -> UUID? {
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: type == .income ? .income : .expense))
        var draft = EntryDraft(
            typeRaw: type.raw,
            amount: amount,
            occurredDay: 20261120
        )
        draft.accountID = accountID
        draft.toAccountID = toAccountID
        if type != .transfer {
            draft.categoryID = try XCTUnwrap(categories.first?.id)
        }
        return try environment.ledger.create(draft).entryID
    }

    // MARK: - 余额

    func testBalanceIncludesExpenseIncomeAndBothTransferSides() throws {
        let (environment, viewModel) = try makeSUT()

        let cashID = try viewModel.create(name: "现金", kind: .cash, initialBalanceCents: 10_000)
        let bankID = try viewModel.create(name: "储蓄卡", kind: .debit, initialBalanceCents: 0)

        // 支出 3000（现金）
        _ = try createEntry(environment, amount: 3000, accountID: cashID)
        // 收入 1000（现金）
        _ = try createEntry(environment, type: .income, amount: 1000, accountID: cashID)
        // 转出 500（现金 → 储蓄卡）
        _ = try createEntry(environment, type: .transfer, amount: 500, accountID: cashID, toAccountID: bankID)

        viewModel.load()

        let cash = try XCTUnwrap(viewModel.rows.first { $0.id == cashID })
        let bank = try XCTUnwrap(viewModel.rows.first { $0.id == bankID })

        // 10000 − 3000 + 1000 − 500 = 7500
        XCTAssertEqual(cash.balanceCents, 7500, "转账转出必须扣减")
        XCTAssertEqual(bank.balanceCents, 500, "转账转入必须增加")
        XCTAssertEqual(cash.balanceCents + bank.balanceCents, 8000, "转账不能凭空造钱或销钱")
    }

    func testSoftDeletedEntriesDoNotAffectBalanceOrCount() async throws {
        let (environment, viewModel) = try makeSUT()
        let id = try viewModel.create(name: "现金", kind: .cash, initialBalanceCents: 5000)

        let entryID = try XCTUnwrap(
            try createEntry(environment, amount: 2000, accountID: id)
        )

        _ = await environment.ledger.delete(id: entryID)
        viewModel.load()

        let row = try XCTUnwrap(viewModel.rows.first { $0.id == id })
        XCTAssertEqual(row.balanceCents, 5000, "软删的账目不计入余额")
        XCTAssertEqual(row.entryCount, 0, "软删的账目不计入条数")
    }

    // MARK: - 删除降级

    func testDeletingAccountWithEntriesArchivesInstead() throws {
        let (environment, viewModel) = try makeSUT()
        let id = try viewModel.create(name: "招行", kind: .debit, initialBalanceCents: 0)

        _ = try createEntry(environment, amount: 1200, accountID: id)
        viewModel.load()

        let preview = try XCTUnwrap(viewModel.deletePreview(for: id))
        XCTAssertTrue(preview.willArchive)
        XCTAssertEqual(preview.entryCount, 1)
        XCTAssertTrue(preview.message.contains("将改为归档"), "弹窗必须说清后果是归档而不是删除")

        let outcome = try viewModel.delete(id: id)

        XCTAssertEqual(outcome, .archived(entryCount: 1))
        let row = try XCTUnwrap(viewModel.rows.first { $0.id == id })
        XCTAssertTrue(row.isArchived, "账户还在，只是归档了")

        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        XCTAssertTrue(accounts.contains { $0.id == id }, "硬删会让历史账目失去账户引用")
    }

    func testDeletingEmptyAccountReallyDeletesIt() throws {
        let (environment, viewModel) = try makeSUT()
        let id = try viewModel.create(name: "临时", kind: .other, initialBalanceCents: 0)

        let preview = try XCTUnwrap(viewModel.deletePreview(for: id))
        XCTAssertFalse(preview.willArchive)
        XCTAssertTrue(preview.message.contains("无法恢复"))

        XCTAssertEqual(try viewModel.delete(id: id), .deleted)

        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        XCTAssertFalse(accounts.contains { $0.id == id })
        XCTAssertFalse(viewModel.rows.contains { $0.id == id })
    }

    func testArchivedAccountLeavesThePickerButKeepsTheRow() throws {
        let (_, viewModel) = try makeSUT()
        let keepID = try viewModel.create(name: "现金", kind: .cash)
        let archiveID = try viewModel.create(name: "旧卡", kind: .debit)

        try viewModel.archive(id: archiveID)

        XCTAssertTrue(viewModel.rows.contains { $0.id == archiveID }, "归档不等于消失")
        XCTAssertFalse(
            viewModel.selectableRows.contains { $0.id == archiveID },
            "归档账户不能再出现在记账选择器里"
        )
        XCTAssertTrue(viewModel.selectableRows.contains { $0.id == keepID })
        XCTAssertTrue(viewModel.archivedRows.contains { $0.id == archiveID })

        try viewModel.unarchive(id: archiveID)
        XCTAssertTrue(viewModel.selectableRows.contains { $0.id == archiveID })
    }

    // MARK: - 校验与排序

    func testCreateRejectsEmptyName() throws {
        let (_, viewModel) = try makeSUT()

        XCTAssertThrowsError(try viewModel.create(name: "   ", kind: .cash)) { error in
            XCTAssertEqual(error as? AccountManageError, .emptyName)
        }
        XCTAssertFalse(viewModel.rows.contains { $0.name.isEmpty })
    }

    func testCreateTrimsNameAndAppendsSortOrder() throws {
        let (_, viewModel) = try makeSUT()
        let first = try viewModel.create(name: "  现金  ", kind: .cash)

        let row = try XCTUnwrap(viewModel.rows.first { $0.id == first })
        XCTAssertEqual(row.name, "现金", "首尾空格必须去掉")
        XCTAssertEqual(row.sortOrder, 5, "预置 5 个账户之后追加")
    }

    func testUpdateChangesNameKindAndInitialBalanceButNotBalanceDirectly() throws {
        let (environment, viewModel) = try makeSUT()
        let id = try viewModel.create(name: "现金", kind: .cash, initialBalanceCents: 1000)

        _ = try createEntry(environment, amount: 400, accountID: id)

        try viewModel.update(id: id, name: "招行", kind: .debit, initialBalanceCents: 5000)
        viewModel.load()

        let row = try XCTUnwrap(viewModel.rows.first { $0.id == id })
        XCTAssertEqual(row.name, "招行")
        XCTAssertEqual(row.kind, .debit)
        // 余额跟着期初走：5000 − 400 = 4600
        XCTAssertEqual(row.balanceCents, 4600, "余额 = 期初 − 支出，改期初会同步反映")
    }

    func testMoveReordersAndPersistsSortOrder() throws {
        let (_, viewModel) = try makeSUT()
        let id = try viewModel.create(name: "新账户", kind: .cash)

        let lastIndex = max(viewModel.rows.count - 1, 0)
        try viewModel.move(id: id, toIndex: 0)

        XCTAssertEqual(viewModel.rows.first?.id, id, "拖到第一位就该在第一位")
        XCTAssertEqual(viewModel.rows.first?.sortOrder, 0)
        XCTAssertEqual(viewModel.rows.map(\.sortOrder), Array(0..<viewModel.rows.count))
        XCTAssertEqual(viewModel.rows.count, lastIndex + 1)
    }
}
