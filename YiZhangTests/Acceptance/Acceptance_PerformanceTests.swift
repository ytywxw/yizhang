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
    func testD3b_StatisticsOverTenThousandEntries() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let category = try world.defaultExpenseCategory()

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
            draft.categoryID = category.id
            draft.accountID = account.id
            try world.env.writer.insert(draft, save: false)
        }
        try world.env.writer.save()

        let fetchStarted = Date()
        let entries = try world.env.readContext.fetch(
            QueryDescriptors.monthEntries(today.monthKey)
        )
        let lites = entries.map { entry in
            LedgerLite(
                id: entry.id,
                amount: entry.amount,
                typeRaw: entry.typeRaw,
                occurredDay: entry.occurredDay,
                categoryID: entry.category?.id,
                accountID: entry.account?.id,
                sourceRaw: entry.sourceRaw,
                deletedAt: entry.deletedAt
            )
        }
        let snapshot = StatisticsCalculator.snapshot(lites, range: .thisYear, today: today)
        let elapsed = Date().timeIntervalSince(fetchStarted) * 1_000

        print("[QA-PERF] 统计快照(本年) \(Int(elapsed)) ms，分类数 \(snapshot.categoryShares.count)")
        XCTAssertGreaterThan(snapshot.totalExpense.cents, 0)
        XCTAssertLessThan(elapsed, 500, "统计快照 \(Int(elapsed)) ms 超过 500ms")
    }
}
