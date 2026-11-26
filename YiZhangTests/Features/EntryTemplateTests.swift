//
//  EntryTemplateTests.swift
//  一账Tests / Features
//
//  覆盖 V1.1 F-ACC-14「常用记账模板」的两层：
//  ① `EntryViewModel.applyTemplate` —— 六条规则（类型 / 金额 / 分类 / 账户 / 备注 / 日期）；
//  ② `TemplateService` + `TemplateManageViewModel` —— 上限 20、重名、删模板不动账目、
//     拖拽排序（`onMove` 的 `destination` 是**移动前**的插入位置，最容易写反）。
//
//  为什么这些断言值得写：模板的每一条规则都有"看起来也能跑"的错误实现——
//  把 `hasAmount == false` 实现成"清空金额"会让功能废掉一半（PRD 5.3-2 的主力用法就是
//  「咖啡 / 通勤」只固定分类账户）；把日期实现成"恒设今天"会偷偷改掉用户刚选的昨天。
//  这两条都不会崩、不会报错，只会在用户手里慢慢变成"这功能怪怪的"。
//

import XCTest
import SwiftData
@testable import YiZhang

// MARK: - 夹具

/// 三个测试类共用的一组脚手架（不是继承，避免 XCTest 基类里混进测试方法）。
private enum TemplateFixture {

    /// 固定"今天"，避免测试在真实日期上抖动。
    static let today = DateOnly(key: 20261121)

    @MainActor
    static func environment() throws -> AppEnvironment {
        try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
    }

    @MainActor
    static func categoryID(
        _ name: String,
        _ type: EntryType,
        in environment: AppEnvironment
    ) throws -> UUID {
        let categories = try environment.writer.fetch(
            QueryDescriptors.categories(of: type, includeHidden: false)
        )
        return try XCTUnwrap(categories.first { $0.name == name }?.id, "种子数据里应有分类「\(name)」")
    }

    @MainActor
    static func accountID(_ name: String, in environment: AppEnvironment) throws -> UUID {
        let accounts = try environment.writer.fetch(
            QueryDescriptors.accounts(includeArchived: true)
        )
        return try XCTUnwrap(accounts.first { $0.name == name }?.id, "种子数据里应有账户「\(name)」")
    }

    /// 归档一个账户（PRD 5.3-4 的场景：模板存好之后，账户被归档）。
    @MainActor
    static func archiveAccount(_ name: String, in environment: AppEnvironment) throws {
        let accounts = try environment.writer.fetch(
            QueryDescriptors.accounts(includeArchived: true)
        )
        let account = try XCTUnwrap(accounts.first { $0.name == name })
        try environment.writer.update(account) { model in
            model.isArchived = true
        }
        // 归档走的是 `writer.update`，不经过 Service 的 `onDidCommit`；
        // 只读上下文里可能已经登记过这个账户对象，必须换一只新 context 才能读到新值。
        environment.bumpDataVersion()
    }

    /// 隐藏一个分类（模板里的分类"已不可用"）。
    @MainActor
    static func hideCategory(_ name: String, _ type: EntryType, in environment: AppEnvironment) throws {
        let categories = try environment.writer.fetch(
            QueryDescriptors.categories(of: type, includeHidden: true)
        )
        let category = try XCTUnwrap(categories.first { $0.name == name })
        try environment.writer.update(category) { model in
            model.isHidden = true
        }
        environment.bumpDataVersion()
    }

    @MainActor
    @discardableResult
    static func makeTemplate(
        name: String,
        type: EntryType = .expense,
        amount: Int64 = 0,
        hasAmount: Bool = false,
        note: String = "",
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        in environment: AppEnvironment
    ) throws -> TemplateOption {
        let draft = TemplateDraft(
            name: name,
            typeRaw: type.raw,
            amount: amount,
            hasAmount: hasAmount,
            note: note,
            categoryID: categoryID,
            accountID: accountID
        )
        return TemplateOption(try environment.template.create(draft))
    }

    @MainActor
    @discardableResult
    static func insertEntry(
        type: EntryType = .expense,
        amount: Int64 = 2500,
        day: DateOnly = today,
        note: String = "",
        categoryID: UUID,
        accountID: UUID,
        toAccountID: UUID? = nil,
        in environment: AppEnvironment
    ) throws -> UUID {
        var draft = EntryDraft(typeRaw: type.raw, amount: amount, occurredDay: day.key)
        draft.categoryID = type.isTransfer ? nil : categoryID
        draft.accountID = accountID
        draft.toAccountID = toAccountID
        draft.note = note
        let outcome = try environment.ledger.create(draft)
        return try XCTUnwrap(outcome.entryID, "账目应写入成功")
    }

    /// 走一遍「认真填好一笔账」的状态：支出 + 餐饮 + 微信 + ¥88。
    @MainActor
    static func filledViewModel(in environment: AppEnvironment) throws -> (EntryViewModel, UUID, UUID) {
        let category = try categoryID("餐饮", .expense, in: environment)
        let account = try accountID("微信", in: environment)
        let viewModel = EntryViewModel(today: today)
        viewModel.attach(environment)
        viewModel.select(categoryID: category)
        viewModel.select(accountID: account)
        viewModel.amountText = "88"
        return (viewModel, category, account)
    }
}

// MARK: - ① 填表规则的六条

@MainActor
final class EntryTemplateFillTests: XCTestCase {

    /// 规则 ① ② ③ ⑤：一整套都填对（收工标准 ①）。
    func testApplyTemplateFillsEveryField() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            note: "午饭",
            categoryID: category,
            accountID: account,
            in: environment
        )

        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.type, .expense)
        XCTAssertEqual(viewModel.amountText, "25", "¥25 回填成 25，不带多余的 .00")
        XCTAssertEqual(viewModel.amount, Money(cents: 2_500))
        XCTAssertEqual(viewModel.selectedCategoryID, category)
        XCTAssertEqual(viewModel.accountID, account)
        XCTAssertEqual(viewModel.note, "午饭")
        XCTAssertEqual(viewModel.day, TemplateFixture.today)
        XCTAssertNil(viewModel.templateWarning)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 规则 ②：`hasAmount == false` **绝不碰**用户已输入的数字（收工标准 ②）。
    ///
    /// 这条是「咖啡 / 通勤」类模板的全部价值：只固定分类与账户，金额每天自己输。
    func testApplyTemplateLeavesAmountUntouchedWhenHasAmountIsFalse() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "咖啡",
            amount: 0,
            hasAmount: false,
            categoryID: category,
            accountID: account,
            in: environment
        )

        let (viewModel, _, _) = try TemplateFixture.filledViewModel(in: environment)
        XCTAssertEqual(viewModel.amountText, "88")

        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.amountText, "88", "hasAmount == false 时金额必须原样保留")
        XCTAssertEqual(viewModel.amount, Money(cents: 8_800))
        XCTAssertEqual(viewModel.selectedCategoryID, category, "分类照填")
        XCTAssertEqual(viewModel.accountID, account, "账户照填")
    }

    /// 规则 ②：`hasAmount == true` 才覆盖金额，且覆盖是「整份替换」而不是「拼接」。
    func testApplyTemplateOverridesAmountWhenHasAmountIsTrue() throws {
        let environment = try TemplateFixture.environment()
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            in: environment
        )

        let (viewModel, _, _) = try TemplateFixture.filledViewModel(in: environment)
        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.amountText, "25")
    }

    /// 规则 ①：类型跟着模板走，并清掉与新类型不兼容的旧分类。
    ///
    /// 反例（只填金额不换类型）会写出「收入 + 餐饮」这种脏数据。
    func testApplyTemplateFollowsTemplateTypeAndReplacesOldCategory() throws {
        let environment = try TemplateFixture.environment()
        let salary = try TemplateFixture.categoryID("工资", .income, in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "工资",
            type: .income,
            amount: 2_000_000,
            hasAmount: true,
            categoryID: salary,
            in: environment
        )

        let (viewModel, expenseCategory, _) = try TemplateFixture.filledViewModel(in: environment)
        XCTAssertEqual(viewModel.type, .expense)
        XCTAssertEqual(viewModel.selectedCategoryID, expenseCategory)

        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.type, .income)
        XCTAssertEqual(viewModel.selectedCategoryID, salary, "旧支出分类必须被换掉，不能留下收入-餐饮")
        XCTAssertEqual(viewModel.amountText, "20000")
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 规则 ④：用户手动选过的日期不被模板改回今天。
    func testApplyTemplateKeepsManuallyChosenDay() throws {
        let environment = try TemplateFixture.environment()
        let template = try TemplateFixture.makeTemplate(name: "午饭", amount: 2_500, hasAmount: true, in: environment)
        let yesterday = DateOnly(key: 20261120)

        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        viewModel.select(day: yesterday)
        XCTAssertEqual(viewModel.day, yesterday)

        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.day, yesterday, "点了模板就把日期弹回今天 = 偷偷改用户数据")
    }

    /// 规则 ④ 的另一半：`hasCustomDay` 只在"用户真的选了非今天"时为真。
    ///
    /// 编辑模式恒为真：那条账目自带的日期就是用户的数据，模板无权覆盖。
    func testCustomDayFlagTracksManualSelectionAndEditMode() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            categoryID: category,
            accountID: account,
            in: environment
        )
        let yesterday = DateOnly(key: 20261120)

        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        XCTAssertFalse(viewModel.hasCustomDay, "新建默认没有自定义日期")
        viewModel.select(day: yesterday)
        XCTAssertTrue(viewModel.hasCustomDay)
        viewModel.select(day: TemplateFixture.today)
        XCTAssertFalse(viewModel.hasCustomDay, "改回今天 ≈ 没有自定义日期（值相同，无副作用）")

        let snapshot = LedgerEntrySnapshot(
            id: UUID(),
            typeRaw: EntryType.expense.raw,
            amount: 1_200,
            occurredDay: yesterday.key,
            note: "",
            categoryID: category,
            accountID: account
        )
        let editing = EntryViewModel(today: TemplateFixture.today, editing: snapshot)
        XCTAssertTrue(editing.hasCustomDay, "编辑模式的日期是用户数据")
        editing.attach(environment)
        editing.applyTemplate(template)
        XCTAssertEqual(editing.day, yesterday, "编辑时点模板不能把日期改成今天")
    }

    /// 规则 ⑤：分类不可用 → **只降级这一个字段**，账户照填、不弹错误、留一行小字。
    func testApplyTemplateDegradesCategoryOnlyWhenCategoryUnavailable() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            categoryID: category,
            accountID: account,
            in: environment
        )

        // 模板建好之后用户把「餐饮」隐藏了
        try TemplateFixture.hideCategory("餐饮", .expense, in: environment)

        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        XCTAssertFalse(viewModel.expenseCategories.contains { $0.id == category }, "隐藏分类不该出现在宫格里")
        let fallbackCategory = viewModel.effectiveCategoryID

        viewModel.applyTemplate(template)

        XCTAssertNotEqual(viewModel.selectedCategoryID, category, "不可用的分类不能被填进去")
        XCTAssertEqual(
            viewModel.effectiveCategoryID,
            fallbackCategory,
            "该字段保持原样（不改成 nil，也不乱猜）"
        )
        XCTAssertEqual(viewModel.accountID, account, "账户字段必须照填 —— 逐字段降级")
        XCTAssertEqual(viewModel.amountText, "25", "金额字段也照填")
        XCTAssertEqual(viewModel.templateWarning, "模板里的分类已不可用")
        XCTAssertNil(viewModel.errorMessage, "降级不能弹错误（会让人以为整个模板坏了）")
    }

    /// 规则 ⑤：账户已归档 → 分类照填、金额照填，只降级账户（收工标准 ⑦）。
    func testApplyTemplateDegradesAccountOnlyWhenAccountArchived() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let wechat = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            note: "午饭",
            categoryID: category,
            accountID: wechat,
            in: environment
        )

        // 模板建好之后账户被归档（PRD 5.3-4：保留关系，只是不再可选）
        try TemplateFixture.archiveAccount("微信", in: environment)

        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        XCTAssertFalse(viewModel.accounts.contains { $0.id == wechat }, "归档账户不该出现在账户行里")
        XCTAssertTrue(viewModel.archivedAccountIDs.contains(wechat), "但要知道它是归档而不是删除")
        let defaultAccount = viewModel.accountID

        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.selectedCategoryID, category, "分类必须照填 —— 逐字段降级")
        XCTAssertEqual(viewModel.amountText, "25", "金额必须照填")
        XCTAssertEqual(viewModel.note, "午饭", "备注必须照填")
        XCTAssertEqual(viewModel.accountID, defaultAccount, "账户保持当前默认，不被归档账户污染")
        XCTAssertEqual(viewModel.templateWarning, "模板里的账户已归档")
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 规则 ⑤：「账户已删除」与「已归档」必须是两句不同的话。
    ///
    /// 这一支正常写入路径走不到（关系被 nullify 后 `accountID` 就是 nil），
    /// 所以用人造 `TemplateOption` 钉住文案——用户看到「已删除」才知道该重新选账户，
    /// 看到「已归档」才知道去恢复那个账户。
    func testApplyTemplateWarnsWhenAccountWasDeleted() throws {
        let environment = try TemplateFixture.environment()
        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)

        let ghost = TemplateOption(
            id: UUID(),
            name: "幽灵账户",
            amount: 1_000,
            hasAmount: true,
            accountID: UUID()
        )
        viewModel.applyTemplate(ghost)

        XCTAssertEqual(viewModel.templateWarning, "模板里的账户已删除")
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 规则 ⑥：填模板 ≠ 保存（不写账目、不写「上次账户 / 最近分类」）。
    func testApplyTemplateDoesNotSaveEntryOrWriteRecents() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let reminder = try TemplateFixture.categoryID("交通出行", .expense, in: environment)
        environment.settings.rememberCategory(reminder)
        environment.saveSettings()
        let recentBefore = environment.settings.recentCategoryIDList

        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            categoryID: category,
            in: environment
        )
        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        viewModel.applyTemplate(template)

        XCTAssertTrue(
            try environment.ledger.entries(in: TemplateFixture.today.monthKey).isEmpty,
            "填模板不能顺手记一笔"
        )
        XCTAssertEqual(
            environment.settings.recentCategoryIDList,
            recentBefore,
            "「最近分类」只在真正保存时写（F-ACC-07）"
        )
    }

    /// 规则 ⑥ 的下半句：模板值优先于 `applyDefaults()`，且不会被后者的默认账户盖回去。
    func testApplyTemplateBeatsDefaultAccount() throws {
        let environment = try TemplateFixture.environment()
        let cash = try TemplateFixture.accountID("现金", in: environment)
        let wechat = try TemplateFixture.accountID("微信", in: environment)

        // 默认账户设为微信，模板指定现金
        environment.settings.defaultAccountID = wechat
        environment.saveSettings()

        let template = try TemplateFixture.makeTemplate(
            name: "现金午饭",
            amount: 2_500,
            hasAmount: true,
            accountID: cash,
            in: environment
        )
        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        XCTAssertEqual(viewModel.accountID, wechat, "默认值来自设置")

        viewModel.applyTemplate(template)
        XCTAssertEqual(viewModel.accountID, cash, "模板值优先于默认值")

        // 再跑一次 `load()`（例如从设置页回来）也不能把模板值改回默认
        viewModel.reloadTemplates()
        XCTAssertEqual(viewModel.accountID, cash)
    }

    /// 连续点两个模板：旧的降级提示必须被清掉，高亮只反映最后一次。
    func testApplyTemplateClearsPreviousWarning() throws {
        let environment = try TemplateFixture.environment()
        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)

        let broken = TemplateOption(
            id: UUID(),
            name: "幽灵账户",
            amount: 1_000,
            hasAmount: true,
            accountID: UUID()
        )
        viewModel.applyTemplate(broken)
        XCTAssertNotNil(viewModel.templateWarning)

        let healthy = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            in: environment
        )
        viewModel.applyTemplate(healthy)
        XCTAssertNil(viewModel.templateWarning, "换一个好的模板后旧小字必须消失")

        viewModel.applyTemplate(broken)
        viewModel.dismissTemplateWarning()
        XCTAssertNil(viewModel.templateWarning)
    }

    /// 高亮脉冲：填过的字段立刻亮，`dismiss` 之后不影响其它状态。
    func testApplyTemplateFlashesFilledFields() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            categoryID: category,
            accountID: account,
            in: environment
        )

        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        viewModel.applyTemplate(template)

        XCTAssertEqual(
            viewModel.templateFlash,
            Set([TemplateField.amount, .category, .account]),
            "三个字段都被填了 → 三个都要亮，用户才知道点了有效果"
        )
    }

    /// 只有金额的模板不该让分类 / 账户闪（那会误导成"分类被改了"）。
    func testApplyTemplateFlashesOnlyFieldsItFilled() throws {
        let environment = try TemplateFixture.environment()
        let template = try TemplateFixture.makeTemplate(
            name: "只填金额",
            amount: 1_200,
            hasAmount: true,
            in: environment
        )
        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)
        viewModel.applyTemplate(template)

        XCTAssertEqual(viewModel.templateFlash, Set([TemplateField.amount]))
    }

    /// chip 上的金额后缀：只有 `hasAmount == true` 才显示（PRD 5.1 的 `☕ 咖啡` 例子）。
    func testTemplateOptionAmountSuffixFollowsHasAmount() {
        let withAmount = TemplateOption(id: UUID(), name: "午饭", amount: 2_500, hasAmount: true)
        XCTAssertEqual(withAmount.amountSuffix, "¥25")

        let withoutAmount = TemplateOption(id: UUID(), name: "咖啡", amount: 0, hasAmount: false)
        XCTAssertNil(withoutAmount.amountSuffix)

        let withChange = TemplateOption(id: UUID(), name: "奶茶", amount: 1_850, hasAmount: true)
        XCTAssertEqual(withChange.amountSuffix, "¥18.50")
    }

    /// 模板列表按 `TemplateService.all()` 的顺序进入 ViewModel，**不重排**。
    func testViewModelKeepsServiceOrder() throws {
        let environment = try TemplateFixture.environment()
        try TemplateFixture.makeTemplate(name: "A", in: environment)
        try TemplateFixture.makeTemplate(name: "B", in: environment)
        try TemplateFixture.makeTemplate(name: "C", in: environment)

        let service = try environment.template.all()
        let viewModel = EntryViewModel(today: TemplateFixture.today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.templates.map(\.id), service.map(\.id))
        XCTAssertEqual(viewModel.templates.map(\.name), ["A", "B", "C"])
        XCTAssertTrue(viewModel.canCreateTemplate)
    }
}

// MARK: - ② 服务层：上限 / 删模板不动账目 / 排序 / 重名 / 从账目复制

@MainActor
final class TemplateServiceTests: XCTestCase {

    /// 收工标准 ③：第 21 个创建失败，且文案是给用户看的那一句。
    func testCreatingTwentyFirstTemplateFailsWithLimitMessage() throws {
        let environment = try TemplateFixture.environment()
        for index in 1...TemplateService.limit {
            try TemplateFixture.makeTemplate(name: "模板\(index)", in: environment)
        }
        XCTAssertEqual(try environment.template.count(), TemplateService.limit)
        XCTAssertFalse(try environment.template.canCreate())

        let draft = TemplateDraft(name: "第 21 个")
        XCTAssertThrowsError(try environment.template.create(draft)) { error in
            XCTAssertEqual(error as? TemplateError, .limitReached)
            XCTAssertEqual(
                (error as? TemplateError)?.errorDescription,
                "最多 20 个模板，先删一个",
                "置灰提示与抛出的文案必须是同一句，否则用户看到两个说法"
            )
        }
        XCTAssertEqual(try environment.template.count(), TemplateService.limit, "失败不能写进去")
    }

    /// 收工标准 ④：删模板不动任何已生成账目（模板与账目零引用）。
    func testDeletingTemplateDoesNotChangeGeneratedEntries() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let template = try TemplateFixture.makeTemplate(
            name: "午饭",
            amount: 2_500,
            hasAmount: true,
            note: "午饭",
            categoryID: category,
            accountID: account,
            in: environment
        )

        // 用户点了这个模板之后真的记了一笔
        let entryID = try TemplateFixture.insertEntry(
            amount: template.amount,
            note: template.note,
            categoryID: try XCTUnwrap(template.categoryID),
            accountID: try XCTUnwrap(template.accountID),
            in: environment
        )
        let before = LedgerEntrySnapshot(entry: try XCTUnwrap(try environment.ledger.entry(id: entryID)))

        try environment.template.delete(id: template.id)

        XCTAssertEqual(try environment.template.count(), 0)
        let after = LedgerEntrySnapshot(
            entry: try XCTUnwrap(try environment.ledger.entry(id: entryID), "账目必须还在")
        )
        XCTAssertEqual(after.amount, before.amount)
        XCTAssertEqual(after.note, before.note)
        XCTAssertEqual(after.categoryID, before.categoryID)
        XCTAssertEqual(after.accountID, before.accountID)
        XCTAssertEqual(try environment.ledger.entries(in: TemplateFixture.today.monthKey).count, 1)
    }

    /// 收工标准 ⑤：排序落库后，新开的记账页 chips 顺序一致。
    func testReorderIsPersistedAndVisibleToTheNextViewModel() throws {
        let environment = try TemplateFixture.environment()
        let a = try TemplateFixture.makeTemplate(name: "A", in: environment)
        let b = try TemplateFixture.makeTemplate(name: "B", in: environment)
        let c = try TemplateFixture.makeTemplate(name: "C", in: environment)

        try environment.template.reorder(orderedIDs: [c.id, a.id, b.id])

        XCTAssertEqual(try environment.template.all().map(\.name), ["C", "A", "B"])

        // 「重进页面」= 新建一个 ViewModel 再 attach
        let reopened = EntryViewModel(today: TemplateFixture.today)
        reopened.attach(environment)
        XCTAssertEqual(reopened.templates.map(\.name), ["C", "A", "B"], "顺序不能随机换位（PRD 5.3-6）")

        // 再存一次幂等：同样的顺序不该丢
        try environment.template.reorder(orderedIDs: [c.id, a.id, b.id])
        XCTAssertEqual(try environment.template.all().map(\.name), ["C", "A", "B"])
    }

    /// PRD 5.3-8：允许重名，不要偷偷加唯一性校验。
    func testDuplicateNamesAreAllowed() throws {
        let environment = try TemplateFixture.environment()
        try TemplateFixture.makeTemplate(name: "早饭", in: environment)
        try TemplateFixture.makeTemplate(name: "早饭", in: environment)

        XCTAssertEqual(try environment.template.count(), 2, "同名是合法的，用户可能只是没想好名字")
    }

    /// 收工标准 ⑥：从账目存为模板，字段一模一样。
    func testMakeFromEntryCopiesFieldsExactly() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let entryID = try TemplateFixture.insertEntry(
            amount: 2_500,
            note: "午饭",
            categoryID: category,
            accountID: account,
            in: environment
        )

        let created = try environment.template.makeFrom(entryID: entryID, name: "")
        let option = TemplateOption(created)

        XCTAssertEqual(option.name, "午饭", "默认名 = 备注")
        XCTAssertEqual(option.type, .expense)
        XCTAssertEqual(option.amount, 2_500)
        XCTAssertTrue(option.hasAmount, "有金额的账目 → hasAmount 跟随原账目")
        XCTAssertEqual(option.note, "午饭")
        XCTAssertEqual(option.categoryID, category)
        XCTAssertEqual(option.accountID, account)

        // 管理页看得到同一个东西
        let manage = TemplateManageViewModel()
        manage.attach(environment)
        XCTAssertEqual(manage.templates.count, 1)
        XCTAssertEqual(manage.subtitle(for: option), "餐饮 · 微信")
    }

    /// 备注为空时默认名退回分类名；两者都空时退回类型名（由 View 兜底，服务只保证非空）。
    func testMakeFromEntryFallsBackToCategoryName() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let entryID = try TemplateFixture.insertEntry(
            amount: 2_500,
            note: "",
            categoryID: category,
            accountID: account,
            in: environment
        )

        let created = try environment.template.makeFrom(entryID: entryID, name: "")
        XCTAssertEqual(created.name, "餐饮", "没有备注就用分类名")
    }

    /// 转账账目也能存模板：类型收敛成支出，但金额 / 备注 / 账户都保留。
    func testMakeFromTransferEntryKeepsAmountAndAccount() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let cash = try TemplateFixture.accountID("现金", in: environment)
        let wechat = try TemplateFixture.accountID("微信", in: environment)
        let entryID = try TemplateFixture.insertEntry(
            type: .transfer,
            amount: 10_000,
            note: "转给微信",
            categoryID: category,
            accountID: cash,
            toAccountID: wechat,
            in: environment
        )

        let option = TemplateOption(try environment.template.makeFrom(entryID: entryID, name: ""))
        XCTAssertEqual(option.type, .expense, "模板不支持转账，收敛成支出")
        XCTAssertEqual(option.amount, 10_000)
        XCTAssertEqual(option.accountID, cash)
        XCTAssertEqual(option.note, "转给微信")
    }

    /// 源账目不存在 → 抛 `entryNotFound`（复用账目错误，不给 `TemplateError` 加第四个 case）。
    func testMakeFromMissingEntryThrows() throws {
        let environment = try TemplateFixture.environment()
        XCTAssertThrowsError(try environment.template.makeFrom(entryID: UUID(), name: "x")) { error in
            XCTAssertEqual(error as? LedgerError, .entryNotFound)
        }
    }

    /// 名字校验：空 / 超长 / 首尾空白。
    func testNameValidation() throws {
        let environment = try TemplateFixture.environment()
        XCTAssertThrowsError(try environment.template.create(TemplateDraft(name: "   "))) { error in
            XCTAssertEqual(error as? TemplateError, .nameEmpty)
        }
        XCTAssertThrowsError(
            try environment.template.create(TemplateDraft(name: String(repeating: "字", count: 21)))
        ) { error in
            XCTAssertEqual(error as? TemplateError, .nameTooLong)
        }
        // 首尾空白会被去掉，不会算进长度
        let created = try environment.template.create(TemplateDraft(name: "  午饭  "))
        XCTAssertEqual(created.name, "午饭")
    }

    /// `hasAmount == false` 落库时把 `amount` 清零，避免"带着上一次的 25 元"的脏数据。
    func testDraftWithoutAmountStoresZero() throws {
        let environment = try TemplateFixture.environment()
        let created = try environment.template.create(
            TemplateDraft(name: "咖啡", amount: 2_500, hasAmount: false)
        )
        XCTAssertEqual(created.amount, 0)
        XCTAssertFalse(created.hasAmount)
    }
}

// MARK: - ③ 管理页

@MainActor
final class TemplateManageViewModelTests: XCTestCase {

    private func makeViewModel(
        count: Int,
        in environment: AppEnvironment
    ) throws -> ([TemplateOption], TemplateManageViewModel) {
        var created: [TemplateOption] = []
        for index in 0..<count {
            let option = try TemplateFixture.makeTemplate(name: "模板\(index)", in: environment)
            created.append(option)
        }
        let viewModel = TemplateManageViewModel()
        viewModel.attach(environment)
        return (created, viewModel)
    }

    /// `onMove` 的单条下移：`destination` 是**移动前**的插入位置，最容易写反。
    func testMoveSingleItemToEnd() throws {
        let environment = try TemplateFixture.environment()
        let (_, viewModel) = try makeViewModel(count: 3, in: environment)
        XCTAssertEqual(viewModel.templates.map(\.name), ["模板0", "模板1", "模板2"])

        viewModel.move(from: IndexSet(integer: 0), to: 3)

        XCTAssertEqual(viewModel.templates.map(\.name), ["模板1", "模板2", "模板0"])
        XCTAssertEqual(try environment.template.all().map(\.name), ["模板1", "模板2", "模板0"], "顺序必须落库")
    }

    /// 多条一起移动：`destination` 落在这批之后，要先扣掉"落在它前面且被移走的个数"。
    func testMoveMultipleItems() throws {
        let environment = try TemplateFixture.environment()
        let (_, viewModel) = try makeViewModel(count: 3, in: environment)

        viewModel.move(from: IndexSet([0, 1]), to: 3)

        XCTAssertEqual(viewModel.templates.map(\.name), ["模板2", "模板0", "模板1"])
        XCTAssertEqual(try environment.template.all().map(\.name), ["模板2", "模板0", "模板1"])
    }

    /// 移动到最前：`destination == 0`。
    func testMoveItemToFront() throws {
        let environment = try TemplateFixture.environment()
        let (_, viewModel) = try makeViewModel(count: 3, in: environment)

        viewModel.move(from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(viewModel.templates.map(\.name), ["模板2", "模板0", "模板1"])
    }

    /// 满 20：`＋` 置灰、副标题 20/20、页脚给出那一句提示。
    func testLimitDisablesCreateAndShowsHint() throws {
        let environment = try TemplateFixture.environment()
        let (_, viewModel) = try makeViewModel(count: TemplateService.limit, in: environment)

        XCTAssertEqual(viewModel.templates.count, TemplateService.limit)
        XCTAssertFalse(viewModel.canCreate, "满 20 时＋必须置灰")
        XCTAssertEqual(viewModel.countText, "20/20")
        XCTAssertEqual(viewModel.limitHint, "最多 20 个模板，先删一个")
        XCTAssertTrue(viewModel.canReorder)

        // 删一个就恢复
        let victim = try XCTUnwrap(viewModel.templates.first)
        try viewModel.delete(id: victim.id)
        XCTAssertTrue(viewModel.canCreate)
        XCTAssertNil(viewModel.limitHint)
        XCTAssertEqual(viewModel.countText, "19/20")
    }

    /// 左滑删除（`onDelete` 给的是下标集合）。
    func testDeleteAtOffsets() throws {
        let environment = try TemplateFixture.environment()
        let (created, viewModel) = try makeViewModel(count: 3, in: environment)

        viewModel.delete(at: IndexSet(integer: 1))

        XCTAssertEqual(viewModel.templates.map(\.id), [created[0].id, created[2].id])
        XCTAssertEqual(try environment.template.count(), 2)
    }

    /// 写入失败必须抛出来，且列表不能被改脏。
    func testCreateFailureLeavesListUnchanged() throws {
        let environment = try TemplateFixture.environment()
        let (_, viewModel) = try makeViewModel(count: 2, in: environment)

        XCTAssertThrowsError(try viewModel.create(TemplateDraft(name: ""))) { error in
            XCTAssertEqual(error as? TemplateError, .nameEmpty)
        }
        XCTAssertEqual(viewModel.templates.count, 2, "失败不能改列表")
        XCTAssertNil(viewModel.errorMessage, "抛出的错误由表单展示，不进列表页的红字")
    }

    /// 编辑：整份替换，且列表立刻反映新值。
    func testUpdateReplacesWholeDraft() throws {
        let environment = try TemplateFixture.environment()
        let (created, viewModel) = try makeViewModel(count: 1, in: environment)
        let salary = try TemplateFixture.categoryID("工资", .income, in: environment)

        try viewModel.update(
            id: created[0].id,
            changing: TemplateDraft(
                name: "发工资",
                typeRaw: EntryType.income.raw,
                amount: 2_000_000,
                hasAmount: true,
                note: "月薪",
                categoryID: salary,
                accountID: nil
            )
        )

        let updated = try XCTUnwrap(viewModel.templates.first)
        XCTAssertEqual(updated.name, "发工资")
        XCTAssertEqual(updated.type, .income)
        XCTAssertEqual(updated.amount, 2_000_000)
        XCTAssertTrue(updated.hasAmount)
        XCTAssertEqual(updated.note, "月薪")
        XCTAssertEqual(updated.categoryID, salary)
        XCTAssertNil(updated.accountID, "清空账户要能表达出来")
        XCTAssertEqual(viewModel.subtitle(for: updated), "工资 · 不指定账户")
    }

    /// 编辑表单的初始值：`TemplateDraft(template:)` 必须与 `TemplateOption` 一一对应。
    func testDraftRoundTripsFromOption() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let account = try TemplateFixture.accountID("微信", in: environment)
        let option = try TemplateFixture.makeTemplate(
            name: "午饭",
            type: .income,
            amount: 2_500,
            hasAmount: true,
            note: "备注",
            categoryID: category,
            accountID: account,
            in: environment
        )

        let draft = TemplateDraft(template: option)
        XCTAssertEqual(draft.name, "午饭")
        XCTAssertEqual(draft.type, .income)
        XCTAssertEqual(draft.amount, 2_500)
        XCTAssertTrue(draft.hasAmount)
        XCTAssertEqual(draft.note, "备注")
        XCTAssertEqual(draft.categoryID, category)
        XCTAssertEqual(draft.accountID, account)
    }

    /// 副标题：归档账户加「（已归档）」，没账户写「不指定账户」，没分类不进字。
    func testSubtitleCoversArchivedAndEmptyAccount() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let wechat = try TemplateFixture.accountID("微信", in: environment)
        let withAccount = try TemplateFixture.makeTemplate(
            name: "午饭",
            categoryID: category,
            accountID: wechat,
            in: environment
        )
        let withoutAnything = try TemplateFixture.makeTemplate(name: "空模板", in: environment)

        let viewModel = TemplateManageViewModel()
        viewModel.attach(environment)
        XCTAssertEqual(viewModel.subtitle(for: withAccount), "餐饮 · 微信")
        XCTAssertEqual(viewModel.subtitle(for: withoutAnything), "不指定账户")

        try TemplateFixture.archiveAccount("微信", in: environment)
        let refreshed = TemplateManageViewModel()
        refreshed.attach(environment)
        XCTAssertEqual(refreshed.subtitle(for: withAccount), "餐饮 · 微信（已归档）")
    }

    /// 图标：有分类用它自己的，没分类给中性图标（不能崩也不能空白）。
    func testIconNameFallsBackToTag() throws {
        let environment = try TemplateFixture.environment()
        let category = try TemplateFixture.categoryID("餐饮", .expense, in: environment)
        let withCategory = try TemplateFixture.makeTemplate(name: "午饭", categoryID: category, in: environment)
        let withoutCategory = try TemplateFixture.makeTemplate(name: "空模板", in: environment)

        let viewModel = TemplateManageViewModel()
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.iconName(for: withCategory), "fork.knife")
        XCTAssertEqual(viewModel.iconName(for: withoutCategory), "tag")

        let ghost = TemplateOption(id: UUID(), name: "幽灵", categoryID: UUID())
        XCTAssertEqual(viewModel.iconName(for: ghost), "tag", "分类已被删也要有图标")
    }

    /// 只有 1 条时不给排序按钮（拖拽没有意义）。
    func testCanReorderRequiresAtLeastTwoTemplates() throws {
        let environment = try TemplateFixture.environment()
        let (_, empty) = try makeViewModel(count: 0, in: environment)
        XCTAssertFalse(empty.canReorder)
        XCTAssertEqual(empty.countText, "0/20")
        XCTAssertTrue(empty.canCreate)

        let (_, single) = try makeViewModel(count: 1, in: environment)
        XCTAssertFalse(single.canReorder)
        XCTAssertEqual(single.countText, "1/20")
    }
}
