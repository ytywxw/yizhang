//
//  AccountBalanceCalculatorTests.swift
//  一账Tests / Domain
//
//  验证 R-ACC-1：`期初 - Σ支出 + Σ收入 - Σ转出 + Σ转入`。
//  纯函数、0 个数据库，因此这里可以穷举边界（软删、转账两侧、信用卡、自转）。
//

import XCTest
@testable import YiZhang

final class AccountBalanceCalculatorTests: XCTestCase {

    private let cashID = UUID()
    private let cardID = UUID()

    private func account(initial: Int64, kind: AccountKind = .cash) -> AccountBalanceCalculator.AccountSnapshot {
        AccountBalanceCalculator.AccountSnapshot(
            id: cashID,
            initialBalanceCents: initial,
            kindRaw: kind.raw
        )
    }

    func testFormulaCoversExpenseIncomeAndBothTransferSides() {
        // 期初 1000 元，支出 200、收入 500、转出 100、转入 50 → 1250 元
        let movements: [AccountBalanceCalculator.Movement] = [
            .init(amountCents: 20_000, typeRaw: EntryType.expense.raw, accountID: cashID),
            .init(amountCents: 50_000, typeRaw: EntryType.income.raw, accountID: cashID),
            .init(amountCents: 10_000, typeRaw: EntryType.transfer.raw, accountID: cashID, toAccountID: cardID),
            .init(amountCents: 5_000, typeRaw: EntryType.transfer.raw, accountID: cardID, toAccountID: cashID)
        ]

        let balance = AccountBalanceCalculator.balance(
            account: account(initial: 100_000),
            movements: movements
        )

        XCTAssertEqual(balance, Money(cents: 125_000))
        XCTAssertEqual(balance.formatted(), "¥1,250.00".replacingOccurrences(of: ",", with: ""))
    }

    func testSoftDeletedMovementsAreIgnored() {
        let movements: [AccountBalanceCalculator.Movement] = [
            .init(amountCents: 20_000, typeRaw: EntryType.expense.raw, accountID: cashID),
            .init(amountCents: 90_000, typeRaw: EntryType.expense.raw, accountID: cashID, isDeleted: true)
        ]

        let balance = AccountBalanceCalculator.balance(account: account(initial: 100_000), movements: movements)
        XCTAssertEqual(balance, Money(cents: 80_000))
    }

    func testUnrelatedMovementsDoNotAffectBalance() {
        let otherID = UUID()
        let movements: [AccountBalanceCalculator.Movement] = [
            .init(amountCents: 20_000, typeRaw: EntryType.expense.raw, accountID: otherID),
            .init(amountCents: 50_000, typeRaw: EntryType.income.raw, accountID: otherID),
            .init(amountCents: 10_000, typeRaw: EntryType.transfer.raw, accountID: otherID, toAccountID: UUID())
        ]

        let balance = AccountBalanceCalculator.balance(account: account(initial: 100_000), movements: movements)
        XCTAssertEqual(balance, Money(cents: 100_000))
    }

    func testCreditCardUsesTheSameFormulaAndMayGoNegative() {
        // 信用卡：期初 0，刷了 300 元 → -300（欠款为负，R-ACC-3 不为信用卡做特殊数学）
        let movements: [AccountBalanceCalculator.Movement] = [
            .init(amountCents: 30_000, typeRaw: EntryType.expense.raw, accountID: cashID)
        ]

        let balance = AccountBalanceCalculator.balance(
            account: account(initial: 0, kind: .credit),
            movements: movements
        )
        XCTAssertEqual(balance, Money(cents: -30_000))
        XCTAssertTrue(balance.isNegative)
    }

    func testSelfTransferCountsOnce() {
        // 脏数据：转出与转入是同一账户，只能算一次转出，否则余额被翻倍
        let movements: [AccountBalanceCalculator.Movement] = [
            .init(amountCents: 10_000, typeRaw: EntryType.transfer.raw, accountID: cashID, toAccountID: cashID)
        ]

        let balance = AccountBalanceCalculator.balance(account: account(initial: 100_000), movements: movements)
        XCTAssertEqual(balance, Money(cents: 90_000))
    }

    func testSignedDeltaForEachCase() {
        let expense = AccountBalanceCalculator.Movement(
            amountCents: 100, typeRaw: EntryType.expense.raw, accountID: cashID
        )
        XCTAssertEqual(AccountBalanceCalculator.signedDelta(for: expense, accountID: cashID), Money(cents: -100))
        XCTAssertNil(AccountBalanceCalculator.signedDelta(for: expense, accountID: cardID))

        let income = AccountBalanceCalculator.Movement(
            amountCents: 100, typeRaw: EntryType.income.raw, accountID: cashID
        )
        XCTAssertEqual(AccountBalanceCalculator.signedDelta(for: income, accountID: cashID), Money(cents: 100))

        let outbound = AccountBalanceCalculator.Movement(
            amountCents: 100, typeRaw: EntryType.transfer.raw, accountID: cashID, toAccountID: cardID
        )
        XCTAssertEqual(AccountBalanceCalculator.signedDelta(for: outbound, accountID: cashID), Money(cents: -100))
        XCTAssertEqual(AccountBalanceCalculator.signedDelta(for: outbound, accountID: cardID), Money(cents: 100))
    }

    func testEmptyMovementsReturnsInitialBalance() {
        let balance = AccountBalanceCalculator.balance(account: account(initial: 12_345), movements: [])
        XCTAssertEqual(balance, Money(cents: 12_345))
    }
}
