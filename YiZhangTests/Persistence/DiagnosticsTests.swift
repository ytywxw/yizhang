//
//  DiagnosticsTests.swift
//  一账Tests / Persistence
//
//  T23 把自检拆成 `detect`（纯读）与 `repair`（显式修）之后，必须证明三件事：
//  ① `detect` **真的不改数据**——否则"Release 只记录不修"就是一句空话；
//  ② `repair` 只碰重复幂等键，不越界去"顺手"改孤儿引用或过期订阅日；
//  ③ 新增的第五项检查（active 但 `nextBillingDay` 在过去）能抓到 D21 那类问题。
//
//  这三条如果没测试，下一次重构很容易又把手写糊回一个 `run()` 里，
//  而那种回归在运行时是完全静默的（自检通过 = 什么都不打印）。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class DiagnosticsTests: XCTestCase {

    private func makeEnvironment() throws -> (AppEnvironment, ModelContainer) {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        return (environment, container)
    }

    /// 造一条重复幂等键的账目（模拟"某条写入路径漏了查重"）。
    ///
    /// 注意不能连着调两次 `ledger.create`：第二层幂等防线会直接跳过第二条，
    /// 造不出重复。真实的重复来自"某处改写了 uniqueKey"或"绕过了写入服务"，
    /// 所以这里先正常插两条，再把其中一条的键改成与另一条相同。
    private func insertDuplicate(in environment: AppEnvironment, key: String) throws -> [UUID] {
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let categoryID = try XCTUnwrap(categories.first?.id)
        let accountID = try XCTUnwrap(accounts.first?.id)

        var ids: [UUID] = []
        for index in 0..<2 {
            var draft = EntryDraft(amount: 2500, occurredDay: 20261120)
            draft.categoryID = categoryID
            draft.accountID = accountID
            draft.sourceRaw = EntrySource.subscription.raw
            draft.sourceRefID = UUID()
            // 第一条用目标键，第二条先用一个临时键，之后再改成目标键
            draft.uniqueKey = index == 0 ? key : "\(key)|tmp"
            let outcome = try environment.ledger.create(draft)
            if let id = outcome.entryID { ids.append(id) }
        }

        let second = try XCTUnwrap(ids.last)
        try environment.writer.update(id: second) { entry in
            entry.sourceCycleUniqueKey = key
        }
        return ids
    }

    // MARK: - detect 纯读

    func testDetectReportsDuplicatesWithoutModifyingAnything() throws {
        let (environment, container) = try makeEnvironment()
        let key = "\(UUID().uuidString)|2026-11"
        _ = try insertDuplicate(in: environment, key: key)

        let report = try Diagnostics.detect(in: ModelContext(container))

        XCTAssertEqual(report.duplicateUniqueKeyEntries[key]?.count, 2)
        XCTAssertFalse(report.isHealthy)

        // 关键：detect 之后两条都还在（没有软删）
        let entries = try environment.writer.fetch(QueryDescriptors.allEntries())
        XCTAssertEqual(entries.filter { $0.sourceCycleUniqueKey == key && $0.deletedAt == nil }.count, 2,
                       "detect 是纯读，一行都不能改")
    }

    // MARK: - repair 只修重复键

    func testRepairSoftDeletesAllButTheEarliestDuplicate() throws {
        let (environment, container) = try makeEnvironment()
        let key = "\(UUID().uuidString)|2026-12"
        let ids = try insertDuplicate(in: environment, key: key)
        XCTAssertEqual(ids.count, 2)

        let context = ModelContext(container)
        let report = try Diagnostics.detect(in: context)
        let repaired = try Diagnostics.repair(in: context, report: report)

        XCTAssertEqual(repaired, 1, "两条重复只该软删一条")

        let entries = try environment.writer.fetch(QueryDescriptors.allEntries())
        let live = entries.filter { $0.sourceCycleUniqueKey == key && $0.deletedAt == nil }
        XCTAssertEqual(live.count, 1, "修完必须只剩一条有效账目")

        let after = try Diagnostics.detect(in: ModelContext(container))
        XCTAssertTrue(after.isHealthy, "修完再检测应该干净")
    }

    func testRepairLeavesOtherFindingsAlone() throws {
        let (environment, container) = try makeEnvironment()

        // 造一条"状态 active 但下次扣费日在过去"的订阅（D21 类问题）
        let created = try environment.subscription.create(
            SubscriptionDraft(name: "健身房", amount: 9900, firstBillingDay: 20260901),
            today: DateOnly(key: 20260901)
        )
        let stale = try XCTUnwrap(try environment.subscription.subscription(id: created.subscriptionID))
        stale.nextBillingDay = 20260901
        try environment.writer.save()

        let context = ModelContext(container)
        let report = try Diagnostics.detect(in: context)

        XCTAssertEqual(report.staleSubscriptionIDs.count, 1, "第五项检查要能抓到停在过去的订阅")

        let repaired = try Diagnostics.repair(in: context, report: report)
        XCTAssertEqual(repaired, 0, "过期订阅日不归 repair 管（那是业务数据，要人判断）")

        let after = try Diagnostics.detect(in: ModelContext(container))
        XCTAssertEqual(after.staleSubscriptionIDs.count, 1, "repair 不能顺手把订阅日改掉")
    }

    // MARK: - 性能

    func testDetectTwoThousandEntriesUnder30Milliseconds() throws {
        let (environment, container) = try makeEnvironment()
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let categoryID = try XCTUnwrap(categories.first?.id)
        let accountID = try XCTUnwrap(accounts.first?.id)

        for index in 0..<2_000 {
            // 用上个月的日子：本月的部分日期还没到，会被「不能记未来」的校验挡掉
            var draft = EntryDraft(amount: Int64(100 + index % 5000), occurredDay: 20261001 + Int32(index % 28))
            draft.categoryID = categoryID
            draft.accountID = accountID
            _ = try environment.ledger.create(draft, save: false)
        }
        try environment.writer.save()

        let context = ModelContext(container)
        let started = CFAbsoluteTimeGetCurrent()
        let report = try Diagnostics.detect(in: context)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        XCTAssertLessThan(elapsed, 30, "预算 30ms，实测 \(String(format: "%.1f", elapsed))ms")
        XCTAssertTrue(report.isHealthy)
        print("[PERF] diagnostics detect 2000 entries: \(String(format: "%.1f", elapsed))ms")
    }
}

// MARK: - 一次性测量（只在需要时手动打开）
//
// 10k 行的耗时是"架构预算 vs 现实"的对照数据，跑一次约 8 秒，
// 所以不放进常规套件，需要时把下面的 `/*` 与末尾的 `*/` 一起删掉再跑。
/*
extension DiagnosticsTests {
    func testMeasureTenThousandEntries() throws {
        let (environment, container) = try makeEnvironment()
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let categoryID = try XCTUnwrap(categories.first?.id)
        let accountID = try XCTUnwrap(accounts.first?.id)
        for index in 0..<10_000 {
            var draft = EntryDraft(amount: Int64(100 + index % 5000), occurredDay: 20261001 + Int32(index % 28))
            draft.categoryID = categoryID
            draft.accountID = accountID
            _ = try environment.ledger.create(draft, save: false)
        }
        try environment.writer.save()
        let context = ModelContext(container)
        let started = CFAbsoluteTimeGetCurrent()
        _ = try Diagnostics.detect(in: context)
        print("[PERF] diagnostics detect 10000 entries: \((CFAbsoluteTimeGetCurrent() - started) * 1000)ms")
    }
    */
