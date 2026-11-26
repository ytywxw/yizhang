//
//  AccountSharesTests.swift
//  一账Tests / Domain
//
//  统计页「账户支出构成」的口径（V1.1 F-ACC-16，任务书 §2 §5 ⑥⑧⑨）。
//
//  这一组测试守的是一条**用户能当场发现的自相矛盾**：
//  卡片上 6 个账户的金额加起来必须等于顶部合计。差一分钱都会被当成"记账记丢了"。
//  所以每个用例的最后一条断言都是 `Σ shares.amount == snapshot.categoryTotal`，
//  包括合并出「其他」的那两条 —— 合并是最容易漏加/重复加的地方。
//
//  另外两条只在账户维度才会出现的坑：
//  ① 转账必须排除。从储蓄卡转 5000 到支付宝，两个账户各虚增 5000、合计翻倍（PRD 3.3-5）。
//  ② 「没有账户的账目」要并成一个桶，且**不能**用 `nil` 当字典键（`[UUID?: Int64]` 歧义），
//     内部靠哨兵 UUID，出口翻译回 `nil`。哨兵一旦漏出来，卡片上会出现一行
//     `00000000-0000-0000-0000-000000000001`。
//

import XCTest
@testable import YiZhang

final class AccountSharesTests: XCTestCase {

    /// 固定"今天"：2026-11-21（11 月 30 天）。
    private let today = DateOnly(key: 20261121)

    // MARK: - ⑥ 转账不计入任一账户

    func testTransferIsExcludedFromEveryAccountBucket() {
        let wallet = account(1)
        let alipay = account(2)
        let entries = [
            lite(20261102, 1_000, account: wallet),
            lite(20261103, 500, account: alipay),
            // 从钱包转 50,000 到支付宝：两边都不是支出
            // （`LedgerLite` 不含 `toAccountID`：统计口径完全不看转入方，转入方只影响余额）
            lite(20261104, 50_000, type: .transfer, account: wallet)
        ]

        let result = StatisticsCalculator.accountShares(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(result.shares.count, 2, "转账不能凭空造出第三个账户桶")
        XCTAssertEqual(result.shares.map(\.amount.cents), [1_000, 500])
        XCTAssertEqual(result.shares.map(\.accountID), [wallet, alipay])
        XCTAssertTrue(result.mergedIDs.isEmpty)

        // 不变量：账户构成之和 == 顶部合计（同一批账目、同一档 range，靠输入相同）
        let totals = StatisticsCalculator.totals(entries, range: .thisMonth, today: today)
        let snapshot = StatisticsCalculator.snapshot(entries, range: .thisMonth, today: today, metric: .expense)
        XCTAssertEqual(sum(result.shares), 1_500)
        XCTAssertEqual(sum(result.shares), totals.expense.cents)
        XCTAssertEqual(sum(result.shares), snapshot.categoryTotal.cents, "转账若被计入，这里会变成 51,500")
    }

    func testTransferOnlyPeriodProducesNoShares() {
        // 整档只有转账：卡片该走空态，而不是画一个金额为 0 的 100% 条
        let entries = [lite(20261104, 50_000, type: .transfer, account: account(1))]
        let result = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)

        XCTAssertTrue(result.shares.isEmpty)
        XCTAssertTrue(result.mergedIDs.isEmpty)
    }

    // MARK: - ⑧ 没有账户的账目并成「未知账户」

    func testEntriesWithoutAccountAreGroupedIntoUnknownAccount() {
        let wallet = account(1)
        let entries = [
            lite(20261102, 1_000, account: wallet),
            lite(20261103, 300)                       // accountID == nil
        ]

        let result = StatisticsCalculator.accountShares(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today
        )

        XCTAssertEqual(result.shares.count, 2)
        XCTAssertEqual(result.shares.first?.accountID, wallet, "金额大的排前面")

        let unknown = result.shares[1]
        XCTAssertNil(unknown.accountID)
        XCTAssertFalse(unknown.isMerged, "「未知账户」不是合并桶：它不是被挤出来的，而是本来就没有账户")
        XCTAssertEqual(unknown.amount.cents, 300)
        XCTAssertEqual(unknown.id, "unassignedAccount")

        // 哨兵 UUID 绝不能出现在出口类型里（否则界面上会显示一串 UUID）
        XCTAssertFalse(
            result.shares.contains { $0.accountID == StatisticsCalculator.unassignedAccountKey },
            "内部哨兵必须在出口翻译成 nil"
        )

        let snapshot = StatisticsCalculator.snapshot(entries, range: .thisMonth, today: today, metric: .expense)
        XCTAssertEqual(sum(result.shares), 1_300, "未知账户也要参与合计，否则和顶部数字对不上")
        XCTAssertEqual(sum(result.shares), snapshot.categoryTotal.cents)
    }

    func testUnknownAccountAloneIsStillOneShare() {
        let entries = [lite(20261102, 700), lite(20261105, 200)]
        let result = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)

        XCTAssertEqual(result.shares.count, 1)
        XCTAssertEqual(result.shares[0].amount.cents, 900)
        XCTAssertEqual(result.shares[0].percent, 100)
    }

    // MARK: - ⑨ 超过 limit 合并「其他」

    func testExceedingLimitMergesTailIntoOther() {
        let ids = (1...7).map { account($0) }
        let amounts: [Int64] = [700, 600, 500, 400, 300, 200, 100]
        let entries = zip(ids, amounts).map { (id, amount) in lite(20261102, amount, account: id) }

        let result = StatisticsCalculator.accountShares(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today,
            limit: 6
        )

        XCTAssertEqual(result.shares.count, 6, "limit 含「其他」，所以是 5 个真实账户 + 1 个合并桶")
        XCTAssertEqual(result.shares.prefix(5).map(\.amount.cents), [700, 600, 500, 400, 300])
        XCTAssertEqual(result.shares.prefix(5).map(\.isMerged), [false, false, false, false, false])

        let other = result.shares.last
        XCTAssertEqual(other?.isMerged, true)
        XCTAssertNil(other?.accountID)
        XCTAssertEqual(other?.amount.cents, 300, "200 + 100")
        XCTAssertEqual(other?.id, "merged.other")

        XCTAssertEqual(result.mergedIDs, Set([ids[5], ids[6]]), "「其他」下钻必须精确还原被合并的账户")
        XCTAssertEqual(sum(result.shares), 2_800)

        let snapshot = StatisticsCalculator.snapshot(entries, range: .thisMonth, today: today, metric: .expense)
        XCTAssertEqual(sum(result.shares), snapshot.categoryTotal.cents, "合并不许丢钱也不许重复计")
    }

    func testDefaultLimitIsSix() {
        XCTAssertEqual(StatisticsCalculator.accountLimit, 6, "PRD：最多 6 条 + 其他")

        let ids = (1...8).map { account($0) }
        let amounts: [Int64] = [800, 700, 600, 500, 400, 300, 200, 100]
        let entries = zip(ids, amounts).map { (id, amount) in lite(20261102, amount, account: id) }

        let result = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)
        XCTAssertEqual(result.shares.count, 6)
        XCTAssertEqual(result.shares.last?.amount.cents, 600, "300 + 200 + 100")
        XCTAssertEqual(result.mergedIDs, Set([ids[5], ids[6], ids[7]]))
    }

    func testMergedIdsNeverContainTheUnassignedSentinel() {
        // 6 个真实账户 + 1 个「未知账户」，limit = 3 → 尾部是 4 个真实账户 + 哨兵。
        // 哨兵不是真实账户 id，把它塞进 `Set<UUID>` 会让下钻筛出 0 条。
        let ids = (1...6).map { account($0) }
        let amounts: [Int64] = [600, 500, 400, 300, 200, 100]
        var entries = zip(ids, amounts).map { (id, amount) in lite(20261102, amount, account: id) }
        entries.append(lite(20261103, 50))   // accountID == nil

        let result = StatisticsCalculator.accountShares(
            entries,
            range: .thisMonth,
            metric: .expense,
            today: today,
            limit: 3
        )

        XCTAssertEqual(result.shares.count, 3)
        XCTAssertEqual(result.shares.last?.isMerged, true)
        XCTAssertEqual(result.shares.last?.amount.cents, 1_050, "400+300+200+100+50")
        XCTAssertEqual(result.mergedIDs, Set([ids[2], ids[3], ids[4], ids[5]]))
        XCTAssertFalse(result.mergedIDs.contains(StatisticsCalculator.unassignedAccountKey))
        XCTAssertEqual(sum(result.shares), 2_150, "哨兵桶的钱必须算进「其他」，不能丢")
    }

    func testExactlyAtLimitDoesNotMerge() {
        let ids = (1...6).map { account($0) }
        let entries = zip(ids, [600, 500, 400, 300, 200, 100]).map { (id, amount) in lite(20261102, amount, account: id) }

        let result = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)

        XCTAssertEqual(result.shares.count, 6, "正好 6 条不该合并")
        XCTAssertFalse(result.shares.contains { $0.isMerged })
        XCTAssertTrue(result.mergedIDs.isEmpty)
    }

    // MARK: - 排序与占比

    func testSharesAreSortedByAmountDescendingWithStableTieBreak() {
        let small = account(2)
        let big = account(1)
        let entries = [
            lite(20261102, 100, account: small),
            lite(20261103, 900, account: big),
            lite(20261104, 100, account: account(3))
        ]

        let first = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)
        let second = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)

        XCTAssertEqual(first.shares.map(\.amount.cents), [900, 100, 100])
        XCTAssertEqual(first.shares.map(\.id), second.shares.map(\.id), "刷新不能换位置")
        // 同金额时按 uuidString 升序，所以 account(2) 排在 account(3) 前
        XCTAssertEqual(first.shares[1].accountID, account(2))
        XCTAssertEqual(first.shares[2].accountID, account(3))
    }

    func testRatiosSumToOneAndPercentIsRoundedToInteger() {
        let entries = [
            lite(20261102, 700, account: account(1)),
            lite(20261103, 200, account: account(2)),
            lite(20261104, 100, account: account(3))
        ]

        let result = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)

        let ratioSum = result.shares.reduce(0.0) { $0 + $1.ratio }
        XCTAssertEqual(ratioSum, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(result.shares.map(\.percent), [70, 20, 10])
    }

    // MARK: - 口径：范围 / 类型 / 软删

    func testOtherRangesAndMetricsAreScoped() {
        let wallet = account(1)
        let entries = [
            lite(20261102, 1_000, account: wallet),
            lite(20261015, 2_000, account: wallet),                 // 上月
            lite(20261103, 5_000, type: .income, account: wallet)   // 收入
        ]

        let thisMonthExpense = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)
        XCTAssertEqual(sum(thisMonthExpense.shares), 1_000, "上月与收入都不能进来")

        let lastMonthExpense = StatisticsCalculator.accountShares(entries, range: .lastMonth, metric: .expense, today: today)
        XCTAssertEqual(sum(lastMonthExpense.shares), 2_000)

        let thisYearIncome = StatisticsCalculator.accountShares(entries, range: .thisYear, metric: .income, today: today)
        XCTAssertEqual(thisYearIncome.shares.count, 1)
        XCTAssertEqual(thisYearIncome.shares[0].amount.cents, 5_000)

        let lastMonthSnapshot = StatisticsCalculator.snapshot(entries, range: .lastMonth, today: today, metric: .expense)
        XCTAssertEqual(sum(lastMonthExpense.shares), lastMonthSnapshot.categoryTotal.cents)
    }

    func testSoftDeletedAndNonPositiveAmountsAreExcluded() {
        let wallet = account(1)
        let entries = [
            lite(20261102, 1_000, account: wallet),
            lite(20261103, 500, account: wallet, deleted: true),
            lite(20261104, 0, account: wallet)
        ]

        let result = StatisticsCalculator.accountShares(entries, range: .thisMonth, metric: .expense, today: today)

        XCTAssertEqual(sum(result.shares), 1_000, "软删与 0 元都不能占构成")
        let snapshot = StatisticsCalculator.snapshot(entries, range: .thisMonth, today: today, metric: .expense)
        XCTAssertEqual(sum(result.shares), snapshot.categoryTotal.cents)
    }

    func testEmptyInputProducesNoShares() {
        let result = StatisticsCalculator.accountShares([], range: .thisMonth, metric: .expense, today: today)
        XCTAssertTrue(result.shares.isEmpty)
        XCTAssertTrue(result.mergedIDs.isEmpty)
    }

    // MARK: - 夹具

    /// 账户 id 前缀用 `000a`：避开 `unassignedAccountKey`（`...-0000-000000000001`），
    /// 也避开分类测试的 `...-000000000001`。撞上哨兵会让断言出现无法解释的偏差。
    private func account(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-000a-%012d", index)) ?? UUID()
    }

    private func lite(
        _ day: Int32,
        _ amount: Int64,
        type: EntryType = .expense,
        account: UUID? = nil,
        deleted: Bool = false
    ) -> LedgerLite {
        LedgerLite(
            id: UUID(),
            amount: amount,
            typeRaw: type.raw,
            occurredDay: day,
            accountID: account,
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        )
    }

    private func sum(_ shares: [AccountShare]) -> Int64 {
        shares.reduce(Int64(0)) { $0 + $1.amount.cents }
    }
}
