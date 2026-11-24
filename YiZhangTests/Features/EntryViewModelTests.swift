//
//  EntryViewModelTests.swift
//  一账Tests / Features
//
//  验证 T07 记账输入页的业务判断。这批断言覆盖的是"用户点得到的每一种结果"：
//  ① 金额为空 / 为 0 → 保存按钮禁用（R-IN-1）；
//  ② 只填金额就保存 → 自动选最近用过的分类（R-IN-2，不弹窗）；
//  ③ 转账不能转给自己；
//  ④ 不能记到未来；
//  ⑤ 保存后写回「最近分类」（去重 + 最近优先 + 最多 6 个）；
//  ⑥ 编辑模式按快照回填。
//
//  这些判断全在 ViewModel 里（View 没有任何 `if`），所以不需要起 UI 就能钉死。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class EntryViewModelTests: XCTestCase {

    /// 固定"今天"，避免测试在月末/月初因为真实日期而抖动。
    private let today = DateOnly(key: 20261121)

    // MARK: - ① 金额

    func testSaveIsDisabledWhenAmountIsEmptyOrZero() throws {
        let environment = try makeEnvironment()
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertFalse(viewModel.canSave, "金额为空 → 不能保存")
        XCTAssertEqual(viewModel.saveDisabledReason, "输入金额后即可保存")

        viewModel.press(.digit(0))
        XCTAssertEqual(viewModel.amountText, "0")
        XCTAssertFalse(viewModel.canSave, "金额为 0 → 仍然不能保存")

        // `0` 后面再按 5 应该是 5，而不是 05（这是 `AmountInput` 的一条规则）
        viewModel.press(.digit(5))
        XCTAssertEqual(viewModel.amountText, "5")
        XCTAssertTrue(viewModel.canSave, "金额 > 0 且有账户 → 可以保存")
        XCTAssertNil(viewModel.saveDisabledReason)
    }

    func testAmountInputRejectsSecondDotAndThirdFractionDigit() throws {
        let environment = try makeEnvironment()
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)

        viewModel.press(.digit(1))
        viewModel.press(.digit(2))
        viewModel.press(.decimal)
        viewModel.press(.digit(3))
        viewModel.press(.digit(4))
        viewModel.press(.digit(5))   // 第三位小数 → 被挡
        viewModel.press(.decimal)    // 第二个小数点 → 被挡

        XCTAssertEqual(viewModel.amountText, "12.34")
        XCTAssertEqual(viewModel.amount, Money(cents: 1234))

        viewModel.press(.backspace)
        XCTAssertEqual(viewModel.amountText, "12.3")
    }

    // MARK: - ② 自动选分类

    func testSaveAutoSelectsMostRecentCategoryWhenNoneSelected() throws {
        let environment = try makeEnvironment()
        let older = try categoryID(named: "餐饮", type: .expense, in: environment)
        let recent = try categoryID(named: "交通出行", type: .expense, in: environment)

        // 先记「餐饮」再记「交通出行」→ 最近列表应为 [交通出行, 餐饮]
        environment.settings.rememberCategory(older)
        environment.settings.rememberCategory(recent)
        environment.saveSettings()

        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)
        XCTAssertNil(viewModel.selectedCategoryID, "默认不预选分类（保持「未选」的语义）")

        viewModel.press(.digit(3))
        viewModel.press(.digit(2))

        let result = try XCTUnwrap(viewModel.save(), "自动选分类之后应该保存成功：\(viewModel.errorMessage ?? "")")
        XCTAssertEqual(result.amount, Money(cents: 3200), "按 3 再按 2 → 32 元")
        XCTAssertEqual(viewModel.selectedCategoryID, recent, "只填金额 → 自动选最近用过的分类")

        let savedEntry = try environment.ledger.entry(id: result.id)
        let saved = try XCTUnwrap(savedEntry)
        XCTAssertEqual(saved.category?.id, recent, "落库的分类必须是自动选中的那个")
        XCTAssertEqual(saved.note, "")
    }

    func testRecentCategoryOfWrongTypeIsNotAutoSelected() throws {
        let environment = try makeEnvironment()
        let expenseCategory = try categoryID(named: "餐饮", type: .expense, in: environment)
        let incomeCategory = try categoryID(named: "工资", type: .income, in: environment)

        environment.settings.rememberCategory(expenseCategory)
        environment.saveSettings()

        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)
        viewModel.select(type: .income)
        viewModel.press(.digit(9))

        XCTAssertNotEqual(
            viewModel.effectiveCategoryID,
            expenseCategory,
            "收入记账不能自动套用支出分类（否则会写出「收入-餐饮」这种脏数据）"
        )
        XCTAssertEqual(viewModel.effectiveCategoryID, incomeCategory, "同类型没有最近分类时取该类型第一个")
    }

    // MARK: - ③ 转账

    func testTransferRejectsSameAccount() throws {
        let environment = try makeEnvironment()
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)
        viewModel.select(type: .transfer)

        let source = try XCTUnwrap(viewModel.accountID, "转账默认需要一个转出账户")
        XCTAssertNotNil(viewModel.toAccountID, "转账默认要自动补一个不同的转入账户")
        XCTAssertNotEqual(viewModel.toAccountID, source)

        viewModel.select(toAccountID: source)
        XCTAssertEqual(viewModel.errorMessage, "转出和转入不能是同一个账户")
        XCTAssertNotEqual(viewModel.toAccountID, source, "非法选择不生效：转入账户保持不变")

        // 账户列表里转账不出现分类宫格
        XCTAssertTrue(viewModel.categories.isEmpty, "转账没有分类（PRD 3.2.1）")
        XCTAssertNil(viewModel.effectiveCategoryID)
    }

    func testTransferSaveWritesBothAccountsAndNoCategory() throws {
        let environment = try makeEnvironment()
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)
        viewModel.select(type: .transfer)
        viewModel.press(.digit(5))
        viewModel.press(.digit(0))
        viewModel.press(.digit(0))

        let result = try XCTUnwrap(viewModel.save(), "转账应能保存：\(viewModel.errorMessage ?? "")")
        let savedEntry = try environment.ledger.entry(id: result.id)
        let saved = try XCTUnwrap(savedEntry)

        XCTAssertEqual(saved.type, .transfer)
        XCTAssertEqual(saved.amount, 50000)
        XCTAssertNil(saved.category, "转账不挂分类")
        XCTAssertNotNil(saved.account)
        XCTAssertNotNil(saved.toAccount)
        XCTAssertNotEqual(saved.account?.id, saved.toAccount?.id)
    }

    // MARK: - ④ 日期

    func testFutureDateIsRejected() throws {
        let environment = try makeEnvironment()
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)

        viewModel.select(day: today.adding(days: 1))
        XCTAssertEqual(viewModel.errorMessage, "不能记到未来的日期")
        XCTAssertEqual(viewModel.day, today, "非法日期不生效")

        viewModel.select(day: today.adding(days: -1))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.day, today.adding(days: -1), "昨天可以")
    }

    // MARK: - ⑤ 最近分类写回

    func testRecentCategoryIDsAreDedupedAndNewestFirst() throws {
        let environment = try makeEnvironment()
        let food = try categoryID(named: "餐饮", type: .expense, in: environment)
        let transport = try categoryID(named: "交通出行", type: .expense, in: environment)
        let shopping = try categoryID(named: "购物", type: .expense, in: environment)

        try saveViaViewModel(categoryID: food, in: environment)
        XCTAssertEqual(environment.settings.recentCategoryIDList, [food])

        try saveViaViewModel(categoryID: transport, in: environment)
        XCTAssertEqual(environment.settings.recentCategoryIDList, [transport, food])

        // 再用「餐饮」→ 它跳到最前，且不出现重复
        try saveViaViewModel(categoryID: food, in: environment)
        XCTAssertEqual(environment.settings.recentCategoryIDList, [food, transport])
        XCTAssertEqual(
            environment.settings.recentCategoryIDList.filter { $0 == food }.count,
            1,
            "同一个分类只能出现一次"
        )

        // 超过 6 个之后只保留最近 6 个
        for _ in 0..<5 {
            try saveViaViewModel(categoryID: shopping, in: environment)
        }
        XCTAssertLessThanOrEqual(
            environment.settings.recentCategoryIDList.count,
            EntryViewModel.recentCategoryLimit
        )
    }

    func testSaveRemembersDefaultAccount() throws {
        let environment = try makeEnvironment()
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)

        let target = try XCTUnwrap(viewModel.accounts.last?.id, "种子数据至少有一个账户")
        viewModel.select(accountID: target)
        viewModel.press(.digit(1))

        XCTAssertNotNil(viewModel.save())
        XCTAssertEqual(
            environment.settings.defaultAccountID,
            target,
            "保存后要记住这个账户（F-ACC-07：下次记账默认用它）"
        )
    }

    // MARK: - ⑥ 编辑模式

    func testEditModePrefillsFromSnapshot() throws {
        let environment = try makeEnvironment()
        let category = try categoryID(named: "餐饮", type: .expense, in: environment)
        let fallbackAccountID = try firstAccountID(in: environment)
        let account = try XCTUnwrap(environment.settings.defaultAccountID ?? fallbackAccountID)

        let snapshot = LedgerEntrySnapshot(
            id: UUID(),
            typeRaw: EntryType.expense.raw,
            amount: 2850,
            occurredDay: today.key,
            note: "昨天的晚饭",
            categoryID: category,
            accountID: account
        )

        let viewModel = EntryViewModel(today: today, editing: snapshot)
        viewModel.attach(environment)

        XCTAssertTrue(viewModel.isEditing)
        XCTAssertEqual(viewModel.type, .expense)
        XCTAssertEqual(viewModel.amountText, "28.5", "金额回填不能带多余的 0")
        XCTAssertEqual(viewModel.amount, Money(cents: 2850))
        XCTAssertEqual(viewModel.selectedCategoryID, category)
        XCTAssertEqual(viewModel.accountID, account)
        XCTAssertEqual(viewModel.note, "昨天的晚饭")
        XCTAssertEqual(viewModel.day, today)
        XCTAssertTrue(viewModel.canSave)

        // 编辑模式不能被 `applyDefaults` 覆盖成"默认账户"
        viewModel.load()
        XCTAssertEqual(viewModel.accountID, account, "编辑模式再次加载也不能覆盖已有账户")
    }

    func testEditModeUpdatesExistingEntryInsteadOfInserting() throws {
        let environment = try makeEnvironment()
        let category = try categoryID(named: "餐饮", type: .expense, in: environment)

        let created = try saveEntry(categoryID: category, amount: 1000, in: environment)
        let createdEntry = try environment.ledger.entry(id: created)
        let existing = LedgerEntrySnapshot(entry: try XCTUnwrap(createdEntry))

        let viewModel = EntryViewModel(today: today, editing: existing)
        viewModel.attach(environment)
        viewModel.note = "改过了"
        viewModel.press(.digit(2))

        let result = try XCTUnwrap(viewModel.save(), "编辑保存应成功：\(viewModel.errorMessage ?? "")")
        XCTAssertEqual(result.id, created, "编辑不能变成新增")
        XCTAssertTrue(result.isEdit)

        let updatedEntry = try environment.ledger.entry(id: created)
        let updated = try XCTUnwrap(updatedEntry)
        XCTAssertEqual(updated.note, "改过了")
        XCTAssertEqual(viewModel.amountText, "102", "回填 10 之后按 2，整数部分接上去成为 102")
        XCTAssertEqual(updated.amount, 10200)

        let monthEntries = try environment.ledger.entries(in: today.monthKey)
        XCTAssertEqual(monthEntries.count, 1, "编辑不能产生第二条账目")
    }

    // MARK: - 工具

    private func makeEnvironment() throws -> AppEnvironment {
        let container = try ModelContainerFactory.make(inMemory: true)
        return try AppEnvironment(container: container)
    }

    private func categoryID(
        named name: String,
        type: EntryType,
        in environment: AppEnvironment
    ) throws -> UUID {
        let categories = try environment.readContext.fetch(
            QueryDescriptors.categories(of: type, includeHidden: false)
        )
        return try XCTUnwrap(categories.first { $0.name == name }?.id, "种子数据里应有分类「\(name)」")
    }

    private func firstAccountID(in environment: AppEnvironment) throws -> UUID? {
        try environment.readContext.fetch(QueryDescriptors.accounts(includeArchived: false)).first?.id
    }

    /// 走一遍 VM 的保存路径（只有这条路会写回「最近分类」）。
    @discardableResult
    private func saveViaViewModel(
        categoryID: UUID,
        in environment: AppEnvironment
    ) throws -> UUID {
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)
        viewModel.select(categoryID: categoryID)
        viewModel.press(.digit(1))
        let result = try XCTUnwrap(viewModel.save(), "保存应成功：\(viewModel.errorMessage ?? "")")
        return result.id
    }

    @discardableResult
    private func saveEntry(
        categoryID: UUID,
        amount: Int64 = 1200,
        in environment: AppEnvironment
    ) throws -> UUID {
        var draft = EntryDraft(
            typeRaw: EntryType.expense.raw,
            amount: amount,
            occurredDay: today.key
        )
        draft.categoryID = categoryID
        draft.accountID = try firstAccountID(in: environment)
        let outcome = try environment.ledger.create(draft)
        return try XCTUnwrap(outcome.entryID)
    }
}
