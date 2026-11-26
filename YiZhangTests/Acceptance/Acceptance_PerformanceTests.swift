//
//  Acceptance_PerformanceTests.swift
//  YiZhangTests / Acceptance
//
//  独立复核工程师的声明 D3：「1 万条账目下切换月份不卡」。
//  自己造 10 000 条账目、自己计时，不引述任何汇报数字。
//  阈值取「人能感知的卡顿」而不是「机器跑分」：单次切月 > 500ms 就算卡。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class Acceptance_PerformanceTests: XCTestCase {

    private let today = AcceptanceToday.value

    /// 造 10 000 条账目（跨 12 个月），然后计时：冷启动装配、首屏加载、切月。
    func testD3_TenThousandEntriesMonthSwitching() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let category = try world.defaultExpenseCategory()

        let total = 10_000
        let months: [Int32] = [
            202512, 202601, 202602, 202603, 202604, 202605,
            202606, 202607, 202608, 202609, 202610, 202611,
        ]

        let insertStarted = Date()
        for index in 0..<total {
            let month = months[index % months.count]
            let day = month * 100 + Int32(index % 28 + 1)
            var draft = EntryDraft(amount: Int64(index % 900 + 1) * 100, occurredDay: day)
            draft.categoryID = category.id
            draft.accountID = account.id
            draft.note = "压测 \(index)"
            try world.env.writer.insert(draft, save: false)
        }
        try world.env.writer.save()
        let insertSeconds = Date().timeIntervalSince(insertStarted)

        XCTAssertEqual(
            try world.env.readContext.fetchCount(QueryDescriptors.allEntries()),
            total,
            "10 000 条必须真的落库"
        )

        // ① 冷启动装配（同一份存储，全新 env）：种子幂等检查 + context 建立
        let bootStarted = Date()
        let relaunched = try AcceptanceWorld.boot(reusing: world.container)
        let bootMilliseconds = Date().timeIntervalSince(bootStarted) * 1_000

        // ② 首屏加载（当月）
        let home = LedgerHomeViewModel(today: today)
        let firstLoadStarted = Date()
        home.attach(relaunched.env)
        let firstLoadMilliseconds = Date().timeIntervalSince(firstLoadStarted) * 1_000

        XCTAssertGreaterThan(home.entryCount, 0, "当月应当有账目")
        XCTAssertGreaterThan(home.overview.expense.cents, 0)

        // ③ 连续切 5 次月
        var switchMilliseconds: [Double] = []
        for _ in 0..<5 {
            let started = Date()
            home.goPreviousMonth()
            switchMilliseconds.append(Date().timeIntervalSince(started) * 1_000)
        }
        let worstSwitch = switchMilliseconds.max() ?? 0
        let averageSwitch = switchMilliseconds.reduce(0, +) / Double(switchMilliseconds.count)

        print(
            """
            [QA-PERF] 10 000 条账目：
              写入耗时 \(Int(insertSeconds * 1_000)) ms
              冷启动装配 \(Int(bootMilliseconds)) ms
              首屏加载(当月) \(Int(firstLoadMilliseconds)) ms
              切月 avg \(Int(averageSwitch)) ms / worst \(Int(worstSwitch)) ms
              明细 \(switchMilliseconds.map { Int($0) })
            """
        )

        // ③ 的判定：单次切月超过 500ms 就是用户能感知的卡顿
        XCTAssertLessThan(worstSwitch, 500, "切月最慢 \(Int(worstSwitch)) ms，用户能感知到卡顿")
        XCTAssertLessThan(averageSwitch, 300, "切月平均 \(Int(averageSwitch)) ms 偏慢")

        // 冷启动到首屏可交互：PRD §8 要求 ≤ 1.5s（1 万条以内）
        let coldStart = bootMilliseconds + firstLoadMilliseconds
        XCTAssertLessThan(coldStart, 1_500, "冷启动到首屏 \(Int(coldStart)) ms 超过 1.5s 预算")
    }

    /// 统计页取数（本年 = 全部 10 000 条）不得成为瓶颈。
    ///
    /// ⚠️ **必须取全库，不能只取当月**：本用例原先 fetch 的是
    /// `QueryDescriptors.monthEntries(today.monthKey)`（约 833 条），却在注释里宣称
    /// "本年 = 全部 10 000 条" —— 聚合根本没看到那 9 000 多条。V1.1 新增的
    /// `comparison` / `accountShares` 都是**全区间线性扫描**，只在当月数据上测等于没测，
    /// 所以这里改成 `allEntries()`，并断言条数真的等于 10 000。
    func testD3b_StatisticsOverTenThousandEntries() throws {
        let world = try AcceptanceWorld.boot()
        // 刻意**轮着用** 14 个支出分类 + 5 个账户，而不是只塞给第一个：
        // 这两张卡的分桶数直接决定 O(n) 与 O(n·m) 的差别。全塞进一个账户时
        // m = 1，任何"对每个账户扫一遍全部账目"的实现都跟线性扫描一样快，
        // 500ms 阈值就抓不到它了——这个用例的全部意义就在抓这个。
        let accounts = try world.accounts()
        let categories = try world.expenseCategories()
        XCTAssertGreaterThan(accounts.count, 1, "验收前提：种子数据必须有多个账户，否则测不出分桶退化")
        XCTAssertGreaterThan(categories.count, 1, "验收前提：种子数据必须有多个支出分类")

        let months: [Int32] = [
            202601, 202602, 202603, 202604, 202605, 202606,
            202607, 202608, 202609, 202610, 202611, 202612,
        ]
        for index in 0..<10_000 {
            let month = months[index % months.count]
            var draft = EntryDraft(
                amount: Int64(index % 900 + 1) * 100,
                occurredDay: month * 100 + Int32(index % 28 + 1)
            )
            draft.categoryID = categories[index % categories.count].id
            draft.accountID = accounts[index % accounts.count].id
            try world.env.writer.insert(draft, save: false)
        }
        try world.env.writer.save()

        let fetchStarted = Date()
        let entries = try world.env.readContext.fetch(QueryDescriptors.allEntries())
        let lites = entries.map { entry in
            LedgerLite(
                id: entry.id,
                amount: entry.amount,
                typeRaw: entry.typeRaw,
                occurredDay: entry.occurredDay,
                categoryID: entry.category?.id,
                accountID: entry.account?.id,
                sourceRaw: entry.sourceRaw,
                confirmRaw: entry.confirmRaw,
                deletedAt: entry.deletedAt
            )
        }
        let fetchSeconds = Date().timeIntervalSince(fetchStarted)
        XCTAssertEqual(lites.count, 10_000, "聚合必须看到全部 10 000 条，否则这个用例测的是空气")

        // 三段分别计时：拆开才能回答"新增的两次聚合离 500ms 有多远"，
        // 混成一个总数时若某一项退化成 O(n·m)，看不出是哪一项。
        let snapshotStarted = Date()
        let snapshot = StatisticsCalculator.snapshot(lites, range: .thisYear, today: today)
        let snapshotMilliseconds = Date().timeIntervalSince(snapshotStarted) * 1_000

        let comparisonStarted = Date()
        let comparison = StatisticsCalculator.comparison(
            lites, range: .thisYear, metric: .expense, today: today
        )
        let comparisonMilliseconds = Date().timeIntervalSince(comparisonStarted) * 1_000

        let sharesStarted = Date()
        let shares = StatisticsCalculator.accountShares(
            lites, range: .thisYear, metric: .expense, today: today
        )
        let sharesMilliseconds = Date().timeIntervalSince(sharesStarted) * 1_000

        let aggregatesMilliseconds = snapshotMilliseconds + comparisonMilliseconds + sharesMilliseconds

        print(
            """
            [QA-PERF] 统计聚合 @ 10 000 条（本年）：
              取数(fetch + 映射 Lite) \(Int(fetchSeconds * 1_000)) ms
              snapshot            \(Int(snapshotMilliseconds)) ms
              comparison          \(Int(comparisonMilliseconds)) ms
              accountShares       \(Int(sharesMilliseconds)) ms
              三段合计            \(Int(aggregatesMilliseconds)) ms
              分类数 \(snapshot.categoryShares.count) / 账户数 \(shares.shares.count)
            """
        )

        // 非空断言不是形式主义：它们在防止两件事——
        // ① 调用被优化掉/短路返回空（那样"耗时很低"毫无意义）；
        // ② 有人把 range 改成一段没有数据的时间窗，于是这个压测悄悄扫了个空集合。
        XCTAssertGreaterThan(snapshot.totalExpense.cents, 0, "本年必须有支出，否则压测扫的是空集合")
        XCTAssertGreaterThan(
            comparison.yoy.current.cents, 0,
            "同比当期必须是真实合计（为 0 说明区间算错了，不是「没数据」）"
        )
        XCTAssertFalse(shares.shares.isEmpty, "账户构成不能为空")
        XCTAssertEqual(
            shares.shares.reduce(Int64(0)) { $0 + $1.amount.cents },
            snapshot.categoryTotal.cents,
            "账户构成合计恒等于同口径分类合计（两张卡要能互相对账）"
        )

        // 阈值沿用 500ms 而不是 80ms：80ms 在 CI 机器负载波动下会变成随机红灯，
        // 而这条用例要防的是"有人写出 O(n·m)"（10k × 19 分类 = 19 万次比较仍在毫秒级），
        // 500ms 对这类退化足够敏感。
        XCTAssertLessThan(
            aggregatesMilliseconds, 500,
            "三段聚合合计 \(Int(aggregatesMilliseconds)) ms 超过 500ms"
        )
    }
}
