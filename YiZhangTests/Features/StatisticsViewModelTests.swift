//
//  StatisticsViewModelTests.swift
//  一账Tests / Features
//
//  职责：统计页两张新卡（同比环比 / 账户构成）在 **ViewModel 层**的行为
//  （V1.1 F-ACC-16 / 任务书 §3 §5 ⑦）。
//
//  为什么这些用例不能只在 `StatisticsCalculator` 里验：
//  ① **`reload()` 是不是真的把两卡和 `snapshot` 一起重算了**——纯函数全对、
//     但忘了在 `reload()` 里调用，卡片就永远停在初始空态。只有真容器 + 真 `reload()`
//     才能区分"没算"和"算错"。
//  ② **软删之后两卡要同步减少**（任务书 §5-⑦）。漏掉一处就出现"顶部合计少了 400、
//     账户构成没少"这种当场会被用户抓到的矛盾。
//  ③ **账户行的三态文案**（真实账户 / 未知账户 / 已删除账户 / 其他）与
//     **能不能下钻**——这两件事都是"查表结果 + 桶的语义"的合成，只存在于 VM。
//     写错不会崩，只会让用户点进去看到全部账目（比点不动更糟）。
//
//  夹具用真 `AppEnvironment`（内存容器）：`SeedData` 会种 5 个账户 + 预设分类，
//  所以"账户名查表"这条链路是真的走通了，而不是把字典塞进 VM 假装查过。
//

import SwiftData
import XCTest
@testable import YiZhang

@MainActor
final class StatisticsViewModelTests: XCTestCase {

    /// 固定"今天"：2025-11-20（本月档的当期 = 11 月 1–20 日）。
    private let today = DateOnly(key: 20251120)

    // MARK: - ① 挂载即算出两卡

    func testAttachPopulatesBothCardsFromTheSameEntries() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        try insertExpense(environment, amount: 1_000, day: 20251105, account: accounts[0].id)
        try insertExpense(environment, amount: 500, day: 20251116, account: accounts[1].id)

        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertTrue(viewModel.isLoaded)
        XCTAssertEqual(viewModel.snapshot.categoryTotal.cents, 1_500, "顶部合计照旧")
        XCTAssertEqual(viewModel.comparison.current.cents, 1_500, "对比卡主数字要与合计同源")
        XCTAssertEqual(sum(viewModel.accountShares), 1_500, "账户构成之和也要等于合计")
        XCTAssertEqual(viewModel.comparisonBounds.current, 20251101...20251120)
        XCTAssertEqual(viewModel.comparison.yoy.direction, .unavailable, "去年同月没账目")
        XCTAssertEqual(viewModel.accountShares.count, 2)
        XCTAssertTrue(viewModel.mergedAccountIDs.isEmpty, "只有两个账户，不该出现合并桶")
    }

    func testRangeAndMetricChangesRecomputeBothCards() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        try insertExpense(environment, amount: 1_000, day: 20251105, account: accounts[0].id)
        try insertExpense(environment, amount: 2_000, day: 20251015, account: accounts[1].id)
        try insertExpense(environment, amount: 7_000, day: 20251106, account: accounts[0].id, type: .income)

        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        viewModel.range = .lastMonth
        XCTAssertEqual(viewModel.comparison.current.cents, 2_000, "切到上月，两卡都要跟着换口径")
        XCTAssertEqual(sum(viewModel.accountShares), 2_000)
        XCTAssertEqual(viewModel.accountShares.map(\.accountID), [accounts[1].id])
        XCTAssertNotNil(viewModel.comparison.mom, "上月档仍有环比")

        viewModel.range = .thisMonth
        viewModel.metric = .income
        XCTAssertEqual(viewModel.comparison.current.cents, 7_000)
        XCTAssertEqual(sum(viewModel.accountShares), 7_000, "收入口径的账户构成只算收入")
        XCTAssertEqual(viewModel.snapshot.categoryTotal.cents, 7_000)
    }

    // MARK: - ② 软删之后两卡同步减少（任务书 §5-⑦）

    func testSoftDeleteShrinksBothCardsTogether() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        let keeper = try insertExpense(environment, amount: 1_000, day: 20251105, account: accounts[0].id)
        let doomed = try insertExpense(environment, amount: 400, day: 20251106, account: accounts[1].id)

        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)
        XCTAssertEqual(viewModel.comparison.current.cents, 1_400)
        XCTAssertEqual(sum(viewModel.accountShares), 1_400)
        XCTAssertEqual(viewModel.accountShares.count, 2)

        XCTAssertNotNil(keeper)
        try markDeleted(environment, doomed, atDay: today.key)
        viewModel.reload()

        XCTAssertEqual(viewModel.snapshot.categoryTotal.cents, 1_000, "顶部合计先减")
        XCTAssertEqual(viewModel.comparison.current.cents, 1_000, "对比卡必须同步减，不能停留 1,400")
        XCTAssertEqual(sum(viewModel.accountShares), 1_000, "账户构成也必须同步减")
        XCTAssertEqual(viewModel.accountShares.count, 1, "那 400 是第二个账户的全部账目，桶要整个消失")
        XCTAssertEqual(viewModel.accountShares[0].accountID, accounts[0].id)
    }

    // MARK: - ③ 行文案的四种状态

    func testTitleForAccountShareDistinguishesFourStates() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        let real = AccountShare(accountID: accounts[0].id, amount: Money(cents: 100), ratio: 0.5, isMerged: false)
        XCTAssertEqual(viewModel.title(for: real), accounts[0].name, "真实账户显示账户名")

        let unknown = AccountShare(accountID: nil, amount: Money(cents: 100), ratio: 0.5, isMerged: false)
        XCTAssertEqual(viewModel.title(for: unknown), "未知账户", "记账时就没选账户")

        let merged = AccountShare(accountID: nil, amount: Money(cents: 100), ratio: 0.5, isMerged: true)
        XCTAssertEqual(viewModel.title(for: merged), "其他")

        // 账户被删了但账目还在：必须与「未知账户」区分开，否则用户不知道该不该补一条账户
        let orphan = AccountShare(accountID: UUID(), amount: Money(cents: 100), ratio: 0.5, isMerged: false)
        XCTAssertEqual(viewModel.title(for: orphan), "已删除账户")
    }

    func testArchivedAccountIsStillListedAndFlagged() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        let archived = accounts[0]
        try environment.writer.update(archived) { model in
            model.isArchived = true
        }
        try insertExpense(environment, amount: 1_000, day: 20251105, account: archived.id)

        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        let share = try XCTUnwrap(viewModel.accountShares.first)
        XCTAssertEqual(share.accountID, archived.id, "归档账户本档有账目就要照常显示")
        XCTAssertEqual(viewModel.title(for: share), archived.name, "归档不改名字")
        XCTAssertTrue(viewModel.isArchived(share), "行尾要能标「已归档」")

        // 合并桶与「未知账户」永远不是归档
        XCTAssertFalse(viewModel.isArchived(AccountShare(accountID: nil, amount: Money(cents: 1), ratio: 1, isMerged: true)))
        XCTAssertFalse(viewModel.isArchived(AccountShare(accountID: nil, amount: Money(cents: 1), ratio: 1, isMerged: false)))
    }

    // MARK: - ④ 下钻能力

    func testCanDrillForRealAndUnknownAccounts() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        let real = AccountShare(accountID: accounts[0].id, amount: Money(cents: 100), ratio: 1, isMerged: false)
        XCTAssertTrue(viewModel.canDrill(into: real))
        XCTAssertEqual(viewModel.drillAccountIDs(for: real), [accounts[0].id])

        // 「未知账户」不可下钻：`EntryFilter.accountIDs` 表达不了 nil，
        // 空集合会被判成"不过滤"，点进去看到全部账目 —— 比点不动更糟
        let unknown = AccountShare(accountID: nil, amount: Money(cents: 100), ratio: 1, isMerged: false)
        XCTAssertFalse(viewModel.canDrill(into: unknown))
        XCTAssertTrue(viewModel.drillAccountIDs(for: unknown).isEmpty)
    }

    func testMergedShareDrillsOnlyWhenThereAreMergedIDs() throws {
        let environment = try makeEnvironment()
        let accounts = try seededAccounts(environment)
        // 5 个种子账户 + 3 个追加账户 = 8 个桶，cap 6 → 5 个单列 + 3 个合并
        for account in accounts {
            try insertExpense(environment, amount: 100, day: 20251105, account: account.id)
        }
        for index in 0..<3 {
            let extra = try makeAccount(environment, name: "备用卡\(index)")
            try insertExpense(environment, amount: Int64(900 - index * 100), day: 20251106, account: extra.id)
        }

        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.accountShares.count, 6, "5 个单列 + 1 个「其他」")
        XCTAssertEqual(viewModel.mergedAccountIDs.count, 3)
        XCTAssertEqual(sum(viewModel.accountShares), viewModel.snapshot.categoryTotal.cents)

        let merged = try XCTUnwrap(viewModel.accountShares.last)
        XCTAssertTrue(merged.isMerged)
        XCTAssertTrue(viewModel.canDrill(into: merged), "有真实账户被合并时可下钻")
        XCTAssertEqual(viewModel.drillAccountIDs(for: merged), viewModel.mergedAccountIDs, "下钻带的是被合并的账户 id，不是空集合")

        // 防御分支：合并桶存在但 `mergedIDs` 为空（理论上不该发生）时不可下钻，
        // 因为空集合会让 `EntryFilter` 变成"不过滤"
        let emptyMerged = AccountShare(accountID: nil, amount: Money(cents: 1), ratio: 1, isMerged: true)
        let freshViewModel = StatisticsViewModel(today: today)
        freshViewModel.attach(try makeEnvironment())
        XCTAssertTrue(freshViewModel.mergedAccountIDs.isEmpty)
        XCTAssertFalse(freshViewModel.canDrill(into: emptyMerged))
    }

    // MARK: - ⑤ 空态与副标题

    func testIsComparisonEmptyOnlyWhenEverythingIsZero() throws {
        let emptyEnvironment = try makeEnvironment()
        let emptyViewModel = StatisticsViewModel(today: today)
        emptyViewModel.attach(emptyEnvironment)
        XCTAssertTrue(emptyViewModel.isComparisonEmpty, "当期与两个基线都为 0 才是真空")

        // 当期有数 → 不空
        let withCurrent = try makeEnvironment()
        try insertExpense(withCurrent, amount: 1_000, day: 20251105, account: try seededAccounts(withCurrent)[0].id)
        let currentViewModel = StatisticsViewModel(today: today)
        currentViewModel.attach(withCurrent)
        XCTAssertFalse(currentViewModel.isComparisonEmpty)

        // 当期 0、基线有数 → 不空：卡片会显示「¥0.00 ▼100%」，那是有信息量的结论，不能藏
        let withBaselineOnly = try makeEnvironment()
        try insertExpense(withBaselineOnly, amount: 900, day: 20241115, account: try seededAccounts(withBaselineOnly)[0].id)
        let baselineViewModel = StatisticsViewModel(today: today)
        baselineViewModel.attach(withBaselineOnly)
        XCTAssertEqual(baselineViewModel.comparison.current.cents, 0)
        XCTAssertEqual(baselineViewModel.comparison.yoy.baseline.cents, 900)
        XCTAssertFalse(baselineViewModel.isComparisonEmpty, "基线有数时卡片不是空的")
    }

    func testComparisonSubtitleNeverMentionsMonthOverMonthInYearRange() throws {
        let environment = try makeEnvironment()
        let viewModel = StatisticsViewModel(today: today)
        viewModel.attach(environment)

        XCTAssertEqual(viewModel.comparisonSubtitle, "本月至今 · 与去年同月、上月同期比")

        viewModel.range = .lastMonth
        XCTAssertEqual(viewModel.comparisonSubtitle, "上月整月 · 与去年同月、上上月比")

        viewModel.range = .thisYear
        XCTAssertEqual(viewModel.comparisonSubtitle, "本年至今 · 与去年同期比")
        XCTAssertFalse(viewModel.comparisonSubtitle.contains("环比"), "年档没有环比，副标题也不能提")
        XCTAssertFalse(viewModel.comparisonSubtitle.contains("上月"), "年档不能出现「上月」")
        XCTAssertNil(viewModel.comparison.mom)
    }

    // MARK: - 夹具

    private func makeEnvironment() throws -> AppEnvironment {
        try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
    }

    /// 种子里已经种好的 5 个账户（按 `sortOrder` 返回）。
    private func seededAccounts(_ environment: AppEnvironment) throws -> [Account] {
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        XCTAssertGreaterThanOrEqual(accounts.count, 3, "SeedData 必须已种好预设账户，否则这条链路的测试没有意义")
        return accounts
    }

    private func makeAccount(_ environment: AppEnvironment, name: String) throws -> Account {
        let account = Account()
        account.id = UUID()
        account.name = name
        account.kind = .debit
        return try environment.writer.insert(account)
    }

    @discardableResult
    private func insertExpense(
        _ environment: AppEnvironment,
        amount: Int64,
        day: Int32,
        account: UUID,
        type: EntryType = .expense
    ) throws -> UUID {
        var draft = EntryDraft(typeRaw: type.raw, amount: amount, occurredDay: day)
        draft.accountID = account
        draft.categoryID = try environment.writer
            .fetch(QueryDescriptors.categories(of: type)).first?.id
        let outcome = try environment.writer.insert(draft)
        return try XCTUnwrap(outcome.entryID)
    }

    private func markDeleted(_ environment: AppEnvironment, _ entryID: UUID, atDay day: Int32) throws {
        let entry = try XCTUnwrap(try environment.writer.entry(id: entryID))
        try environment.writer.markDeleted(entry, at: DateOnly(key: day).date)
    }

    private func sum(_ shares: [AccountShare]) -> Int64 {
        shares.reduce(Int64(0)) { $0 + $1.amount.cents }
    }
}
