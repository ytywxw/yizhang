//
//  DiagnosticsTests.swift
//  一账Tests / Persistence
//
//  T23 把自检拆成 `detect`（纯读）与 `repair`（显式修）之后，必须证明四件事：
//  ① `detect` **真的不改数据**——否则"Release 只记录不修"就是一句空话；
//  ② `repair` 只碰重复幂等键，不越界去"顺手"改孤儿引用或过期订阅日；
//  ③ 新增的第五项检查（active 但 `nextBillingDay` 在过去）能抓到 D21 那类问题；
//  ④ ②③④ 这三项检查**各自能真的报出数**——不只是在干净库里报 0。
//
//  第四条是补的：前三条只证明了"没乱改"和"第五项能抓"，而第一到第四项检查
//  一直是"干净库里返回 0"就算过。那种断言在检查被整段删掉之后照样绿，
//  等于没测。现在每一项都有一个"造一条破例 → 计数必须变成 1"的反向用例。
//
//  这几条如果没测试，下一次重构很容易又把手写糊回一个 `run()` 里，
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

    // MARK: - ②③④ 正向行为

    /// 造一条干净账目（有分类、有账户、金额为正、日期在过去），返回 id。
    ///
    /// 三条正向用例都走同一个骨架：**干净库基线 0 → 造一个破例 → 1 → 改回去 → 0**。
    /// 基线必须真的干净，否则后面每一条断言测的都是别的东西。
    private func makeHealthyEntry(in environment: AppEnvironment) throws -> UUID {
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        var draft = EntryDraft(amount: 2500, occurredDay: 20261120)
        draft.categoryID = try XCTUnwrap(categories.first?.id)
        draft.accountID = try XCTUnwrap(accounts.first?.id)
        return try XCTUnwrap(try environment.ledger.create(draft).entryID)
    }

    /// ② 孤儿引用：非转账账目少了分类或账户才算，转账两边都缺也不算。
    ///
    /// 走真 `detect` 而不是直接喂 `scan`：这次重构真正的新代码是
    /// `EntrySnapshot.init(_:)` 的那几个字段映射，`hasCategory` / `hasAccount`
    /// 写反了（`!= nil` 写成 `== nil`）只有过一遍真模型才抓得住。
    func testDetectCountsOrphanReferenceButNotForTransfers() throws {
        let (environment, container) = try makeEnvironment()
        let id = try makeHealthyEntry(in: environment)

        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let category = try XCTUnwrap(categories.first)
        let account = try XCTUnwrap(accounts.first)

        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).orphanReferenceCount, 0,
                       "干净账目不能算孤儿")

        // 直接摘掉分类，模拟「绕过服务层写进来的无分类账目 / 历史脏数据」——
        // 正常路径上 `LedgerService` 会拦，所以只能从 writer 这个不校验的后门造
        try environment.writer.update(id: id) { $0.category = nil }

        let report = try Diagnostics.detect(in: ModelContext(container))
        XCTAssertEqual(report.orphanReferenceCount, 1, "无分类的非转账账目必须算孤儿")
        XCTAssertFalse(report.isHealthy, "孤儿要让自检变红，不能只闷头记个数")

        // 账户缺失是另一半判据：分类挂回去、摘账户，计数仍然是 1
        try environment.writer.update(id: id) { entry in
            entry.category = category
            entry.account = nil
        }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).orphanReferenceCount, 1,
                       "无账户也必须算孤儿")

        // 转账没有分类是设计使然（PRD 3.2.1）—— 这条是 `!isTransfer` 前置条件的守门断言，
        // 也是最容易被人"顺手简化"成 (category == nil || account == nil) 的地方
        try environment.writer.update(id: id) { entry in
            entry.type = .transfer
            entry.category = nil
            entry.account = nil
        }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).orphanReferenceCount, 0,
                       "转账两边都缺也不算孤儿")

        // 改回普通支出、分类账户都挂上 → 回到 0，证明这个计数是算出来的、不是粘住的
        try environment.writer.update(id: id) { entry in
            entry.type = .expense
            entry.category = category
            entry.account = account
        }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).orphanReferenceCount, 0,
                       "改回去必须回到 0")
    }

    /// ③ 非法日：`0` 是哨兵，未来是错，**今天必须放过**（判据是 `> today` 而不是 `>=`）。
    func testDetectCountsInvalidDayButNotToday() throws {
        let (environment, container) = try makeEnvironment()
        let id = try makeHealthyEntry(in: environment)
        let todayKey = DateOnly(Date()).key

        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).invalidDayCount, 0,
                       "干净账目不能算非法日")

        // 边界：今天必须放过。实现里把 `>` 写成 `>=` 的话，就是这一条会红
        try environment.writer.update(id: id) { $0.occurredDay = todayKey }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).invalidDayCount, 0,
                       "今天不算非法日：判据是 > today，不是 >=")

        // `0` 是「未设置」的哨兵，不是一个合法的「1 年 1 月 0 日」
        try environment.writer.update(id: id) { $0.occurredDay = 0 }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).invalidDayCount, 1,
                       "0 是哨兵，必须算非法日")

        // 未来日期：`> today.key` 那一支
        try environment.writer.update(id: id) { $0.occurredDay = todayKey + 1 }
        let report = try Diagnostics.detect(in: ModelContext(container))
        XCTAssertEqual(report.invalidDayCount, 1, "未来日期必须算非法日")
        XCTAssertFalse(report.isHealthy, "非法日要让自检变红")

        // 改回今天 → 0
        try environment.writer.update(id: id) { $0.occurredDay = todayKey }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).invalidDayCount, 0,
                       "改回去必须回到 0")
    }

    /// ④ 负金额：A1 的金额是 `Int64` 分、业务规则 `> 0`，负数只能是绕过写入纪律的脏数据。
    ///
    /// 故意**不测 `amount == 0`**：文件头写的是"只允许 > 0"，而实现判的是 `< 0`，
    /// 0 到底算不算异常还没裁定 —— 别用一条测试把没定的口径钉死。
    func testDetectCountsNegativeAmount() throws {
        let (environment, container) = try makeEnvironment()
        let id = try makeHealthyEntry(in: environment)

        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).negativeAmountCount, 0,
                       "正金额不能算负金额")

        try environment.writer.update(id: id) { $0.amount = -1 }
        let report = try Diagnostics.detect(in: ModelContext(container))
        XCTAssertEqual(report.negativeAmountCount, 1, "负金额必须被统计")
        XCTAssertFalse(report.isHealthy, "负金额要让自检变红")

        // 改回正数 → 0
        try environment.writer.update(id: id) { $0.amount = 2500 }
        XCTAssertEqual(try Diagnostics.detect(in: ModelContext(container)).negativeAmountCount, 0,
                       "改回去必须回到 0")
    }

    // MARK: - 性能

    /// 真守门员：**只量我们自己写的那部分**。
    ///
    /// 原先这条量的是 `detect` 全路径，量到的 95% 是 SwiftData 逐行 materialize
    /// （2 000 行 ≈35ms，≈17µs/行，与行数线性、与缓存冷热无关）—— 那部分我们既改不动
    /// 也不该守（冷/热实测 40.9/43.8、43.7/45.6、39.5/38.5、44.9/51.6，热缓存一点没帮忙）。
    /// 现在 `Diagnostics.scan` 是纯函数，喂值类型就能量到真正的复杂度。
    ///
    /// 这条同时钉行为：光有性能绿、检查被删掉，是最糟的一种"通过"。
    func testScanTwoThousandEntriesUnder30Milliseconds() {
        // 今天取远未来：这样「非法日」只可能来自 `occurredDay == 0`，
        // 不随真实日期漂移（否则 2099 年之前跑和之后跑是两条不同的用例）
        let today = DateOnly(key: 20991231)
        let snapshots = Self.makeSnapshots(count: 2_000)

        let started = CFAbsoluteTimeGetCurrent()
        let result = Diagnostics.scan(snapshots, today: today)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        print("[PERF] diagnostics scan 2000 snapshots: \(String(format: "%.1f", elapsed))ms")

        // ②③④：先证明数据真的命中了每一项，再断言计数
        let expectedOrphans = snapshots.filter { !$0.isTransfer && (!$0.hasCategory || !$0.hasAccount) }.count
        let expectedInvalidDays = snapshots.filter { $0.occurredDay == 0 }.count
        let expectedNegatives = snapshots.filter { $0.amount < 0 }.count

        XCTAssertGreaterThan(expectedOrphans, 0, "数据要能命中孤儿引用，否则这条检查被删了测试照样绿")
        XCTAssertGreaterThan(expectedInvalidDays, 0, "数据要能命中非法日")
        XCTAssertGreaterThan(expectedNegatives, 0, "数据要能命中负金额")

        XCTAssertEqual(result.orphanReferenceCount, expectedOrphans)
        XCTAssertEqual(result.invalidDayCount, expectedInvalidDays)
        XCTAssertEqual(result.negativeAmountCount, expectedNegatives)

        // ①：20 个桶 × 10 条；其中 10 个桶整桶已软删 → 只剩 10 个"仍有效"的桶
        XCTAssertEqual(result.duplicateUniqueKeyEntries.count, 20)
        XCTAssertTrue(
            result.duplicateUniqueKeyEntries.values.allSatisfy { $0.count == 10 },
            "① 含软删除记录（R-SUB-7 口径），不能因为删了就不算重复"
        )
        XCTAssertEqual(result.duplicateLiveEntries.count, 10)
        XCTAssertTrue(result.duplicateLiveEntries.values.allSatisfy { $0.count == 10 })

        // ① 的排序口径：createdAt 升序（本例 createdAt 与构造顺序同向且互不相等，
        // 所以"桶内顺序 = 出现顺序"可以直接断言；真出现 createdAt 相等时按 id 兜底）
        for (key, ids) in result.duplicateUniqueKeyEntries {
            let expected = snapshots.filter { $0.sourceCycleUniqueKey == key }.map(\.id)
            XCTAssertEqual(ids, expected, "① 必须按 createdAt 升序（最早者保留）")
        }

        XCTAssertLessThan(elapsed, 30, "预算 30ms，实测 \(String(format: "%.1f", elapsed))ms")
    }

    /// 灾难探针：只防"量级事故"，**不承担回归灵敏度**。
    ///
    /// 2 000 行全表扫的现实中位数 ≈41ms，大头是 SwiftData 逐行 materialize（≈17µs/行），
    /// 不是我们的算法 —— 算法那条由 `testScanTwoThousandEntriesUnder30Milliseconds` 单独盯。
    /// 300ms 这个数只用来抓两类事故：
    ///   ① 有人给每一条账目加了一次 fetch（2 000 × ~0.5ms 就破千毫秒）；
    ///   ② 逐条扫被改成 O(n²)（2 000² 次字符串比较足以破百毫秒）。
    func testDetectTwoThousandEntriesUnderCoarseBudget() throws {
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

        print("[PERF] diagnostics detect 2000 entries (coarse): \(String(format: "%.1f", elapsed))ms")

        XCTAssertLessThan(elapsed, 300, "灾难预算 300ms，实测 \(String(format: "%.1f", elapsed))ms")
        XCTAssertTrue(report.isHealthy)
    }

    // MARK: - 性能用例的夹具

    /// 构造一批投影：②③④ 每一项都要被命中若干条，① 要有"整桶软删"和"整桶存活"两种形态。
    ///
    /// 全部是值类型，不碰 `ModelContext` —— 这正是不需要库也能量 `scan` 的前提。
    private static func makeSnapshots(count: Int) -> [Diagnostics.EntrySnapshot] {
        (0..<count).map { index in
            Diagnostics.EntrySnapshot(
                id: UUID(),
                // 每 10 条有 1 条带幂等键；键名按 index % 200 收拢 → 20 个桶、每桶 10 条
                sourceCycleUniqueKey: index % 10 == 0 ? "dup-\(index % 200)" : nil,
                // 每 20 条软删 1 条。200 是 20 的倍数，所以同一个桶里的 10 条
                // 「要么全删、要么全没删」→ ①b 的桶数正好是①的一半
                deletedAt: index % 20 == 0 ? Date(timeIntervalSince1970: 1) : nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isTransfer: index % 50 == 0,
                hasCategory: index % 7 != 0,
                hasAccount: index % 11 != 0,
                occurredDay: index % 13 == 0 ? 0 : Int32(20261001 + index % 28),
                amount: index % 17 == 0 ? -100 : Int64(100 + index)
            )
        }
    }
}

// MARK: - 一次性测量（只在需要时手动打开）
//
// 10k 行的耗时是"架构预算 vs 现实"的对照数据，跑一次约 80 秒，
// 所以不放进常规套件，需要时把下面的 `/*` 与末尾的 `*/` 一起删掉再跑。
// （实测 2026-11：10 000 行 detect ≈200ms，两轮 201.0 / 204.2ms。）
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
}
*/
