//
//  PerformanceBudgetTests.swift
//  一账Tests / Performance
//
//  T24 要"给数字，不要估算"。这三个场景是最容易被数据量拖垮的：
//
//  ① **订阅扫描**：1 万账目 + 50 个到期订阅，扫描要判定幂等键、生成账目、推进日期。
//     它是**串行**写库路径，一旦 O(N×M)，用户会在冷启动时卡住。
//  ② **切月**：首页按月拉账目 + 分组 + 汇总，是最频繁的交互。
//  ③ **诊断**：已有专门的 `DiagnosticsTests` 覆盖，这里不重复。
//
//  判据用的是真实墙钟（`CFAbsoluteTimeGetCurrent`），但**阈值只给宽松上限**：
//  这几个数字的作用是"防回归到 O(N²)"，不是"校准毫秒"——
//  模拟器和真机的绝对耗时差一倍都正常，卡死的那一类退化会差一个数量级。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class PerformanceBudgetTests: XCTestCase {

    private let entryCount = 10_000
    private let subscriptionCount = 50

    // MARK: - ① 订阅扫描

    func testSweepWithTenThousandEntriesAndFiftySubscriptions() throws {
        let environment = try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
        let today = DateOnly(Date())

        try seedEntries(10_000, into: environment, endingAt: today)
        try seedDueSubscriptions(subscriptionCount, dueOn: today, into: environment)

        // 连跑 3 次、每次换一个"上个月"的扣费日：
        // 同一个周期键第二次扫会被幂等挡掉（那才是正确的空闲态），
        // 要测"真的有活干"的耗时，就得每次给一批新的应扣日。
        var samples: [Double] = []
        let subscriptions = try environment.writer.fetch(QueryDescriptors.allSubscriptions())
        var report = environment.sweep.sweep(today: today, force: true)
        for step in 1...3 {
            let billingDay = Self.monthKey(byGoingBack: step, from: today.key)
            for subscription in subscriptions {
                subscription.nextBillingDay = billingDay
                subscription.statusRaw = SubscriptionStatus.active.raw
            }
            try environment.writer.save()

            let started = CFAbsoluteTimeGetCurrent()
            report = environment.sweep.sweep(today: today, force: true)
            samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }
        let worst = samples.max() ?? 0

        print(String(
            format: "[PERF] sweep 10k entries + 50 subs: %@（每次生成 %d 笔，打标 %d 个，失败 %d）",
            samples.map { String(format: "%.1fms", $0) }.joined(separator: " / "),
            report.inserted,
            report.truncatedSubscriptionIDs.count,
            report.failedSubscriptionIDs.count
        ))

        XCTAssertEqual(report.failedSubscriptionIDs.count, 0, "扫描不允许有失败订阅")
        // 单次扫描的 24 笔上限是**跨订阅合计**的（SweepPlanner.defaultLimit）：
        // 50 个到期订阅第一次扫描只会生成 24 笔，命中上限的那一批打标、下次扫描继续。
        XCTAssertEqual(report.inserted, SweepPlanner.defaultLimit, "单次扫描上限 24 笔（跨订阅合计）")
        // 具体的"哪些订阅被打标"由 `SweepPlannerTests` 逐条覆盖，这里只要确认上限真的生效了
        XCTAssertFalse(report.truncatedSubscriptionIDs.isEmpty, "命中上限必须打标，用户才能看到「订阅周期异常」")
        XCTAssertLessThan(worst, 3_000, "预算 3s，实测最差 \(String(format: "%.0f", worst))ms")
    }

    // MARK: - ② 切月

    func testMonthSwitchWithTenThousandEntries() throws {
        let environment = try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
        let today = DateOnly(Date())

        try seedEntries(entryCount, into: environment, endingAt: today)

        let viewModel = LedgerHomeViewModel()
        viewModel.attach(environment)
        viewModel.load()

        // 切 5 次月，取最大值：单次抖动不该被平均值抹平
        var samples: [Double] = []
        for _ in 0..<5 {
            let started = CFAbsoluteTimeGetCurrent()
            viewModel.goPreviousMonth()
            samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }
        viewModel.goToCurrentMonth()

        let worst = samples.max() ?? 0
        let average = samples.reduce(0, +) / Double(samples.count)
        print(String(
            format: "[PERF] month switch with 10k entries: 平均 %.1fms / 最差 %.1fms",
            average,
            worst
        ))

        XCTAssertLessThan(worst, 400, "切月预算 400ms（超过这个数用户会看到明显的停顿）")
    }

    // MARK: - 夹具

    /// 造 `count` 笔账目，均匀铺在最近 24 个月里（每个月都有数据，切月才有活干）。
    private func seedEntries(_ count: Int, into environment: AppEnvironment, endingAt today: DateOnly) throws {
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accountID = try XCTUnwrap(accounts.first?.id)
        let categoryID = try XCTUnwrap(categories.first?.id)

        // 铺开 24 个月：从 today 往回退 24 个自然月（每月 1 号，避开月末天数差异）
        var days: [Int32] = []
        days.reserveCapacity(24)
        for step in 0..<24 {
            days.append(Self.monthKey(byGoingBack: step, from: today.key))
        }

        for index in 0..<count {
            var draft = EntryDraft(
                amount: Int64(100 + index % 4_000),
                occurredDay: days[index % days.count]
            )
            draft.accountID = accountID
            draft.categoryID = categoryID
            draft.note = "压测第 \(index) 条"
            // 直接走 `LedgerWriter.insert`（跳过 `LedgerService.create` 的逐条校验与幂等查询）：
            // 这是**造数夹具**，不是业务写入路径；用 10k 次 `create` 光造数据就要两分钟，
            // 会把整个测试套件拖成不可用。
            _ = try environment.writer.insert(LedgerEntry(draft: draft), save: false)
        }
        try environment.writer.save()
    }


    /// 返回 `from` 往前 `steps` 个自然月的 1 号（`yyyyMM01`）。
    private static func monthKey(byGoingBack steps: Int, from key: Int32) -> Int32 {
        var year = Int(key / 10_000)
        var month = Int((key / 100) % 100) - steps
        while month <= 0 {
            month += 12
            year -= 1
        }
        return Int32(year * 10_000 + month * 100 + 1)
    }

    private func seedDueSubscriptions(
        _ count: Int,
        dueOn today: DateOnly,
        into environment: AppEnvironment
    ) throws {
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accountID = try XCTUnwrap(accounts.first?.id)
        let categoryID = try XCTUnwrap(categories.first?.id)

        for index in 0..<count {
            let draft = SubscriptionDraft(
                name: "压测订阅 \(index)",
                amount: Int64(900 + index),
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.key,
                nextBillingDay: today.key,
                categoryID: categoryID,
                accountID: accountID
            )
            _ = try environment.subscription.create(draft, today: today)
        }
    }
}
