//
//  Acceptance_BoundaryTests.swift
//  YiZhangTests / Acceptance
//
//  验收范围 B：破坏性 / 边界测试。
//  目标不是"证明它能处理"，而是**问清它在极限输入下是优雅失败还是崩溃**，
//  结论会原样写进验收报告（哪些崩了、哪些优雅处理了）。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class Acceptance_BoundaryTests: XCTestCase {

    private let today = AcceptanceToday.value

    // MARK: - B1 金额 0 / 负数：必须被业务层拒绝

    func testB1_ZeroAndNegativeAmountsAreRejected() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let account = try world.firstAccount()

        var zero = EntryDraft(amount: 0, occurredDay: today.key)
        zero.categoryID = category.id
        zero.accountID = account.id
        XCTAssertThrowsError(try world.env.ledger.create(zero)) { error in
            XCTAssertEqual(error as? LedgerError, .amountNotPositive)
        }

        var negative = EntryDraft(amount: -1, occurredDay: today.key)
        negative.categoryID = category.id
        negative.accountID = account.id
        XCTAssertThrowsError(try world.env.ledger.create(negative)) { error in
            XCTAssertEqual(error as? LedgerError, .amountNotPositive)
        }

        // 金额输入层也不接受负数
        XCTAssertNil(Money.parse("-1"))
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse("1.234"), "多于两位小数必须拒绝，不能悄悄四舍五入")

        XCTAssertEqual(try world.entries().count, 0)
    }

    // MARK: - B2 Int64.max（含 Int64.max + 1 分的解析溢出）

    func testB2_Int64MaxAmountIsHandledWithoutOverflow() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let account = try world.firstAccount()

        var draft = EntryDraft(amount: Int64.max, occurredDay: today.key)
        draft.categoryID = category.id
        draft.accountID = account.id
        let outcome = try world.env.ledger.create(draft)
        guard case .inserted = outcome else {
            return XCTFail("Int64.max 应当能存进库（金额是 Int64 分，不是 Double）")
        }

        // 单笔的月度汇总 = Int64.max，没有溢出
        let summary = try world.env.ledger.monthSummary(monthKey: today.monthKey)
        XCTAssertEqual(summary.expense.cents, Int64.max)
        XCTAssertEqual(summary.balance.cents, -Int64.max, "0 − Int64.max = −Int64.max（精确，不回绕）")

        // 统计侧必须做饱和加法：两笔 Int64.max 相加不得变成负数
        let saturated = StatisticsCalculator.totals(
            [
                LedgerLite(id: UUID(), amount: Int64.max, typeRaw: "expense", occurredDay: today.key),
                LedgerLite(id: UUID(), amount: Int64.max, typeRaw: "expense", occurredDay: today.key),
            ],
            range: .thisMonth,
            today: today
        )
        XCTAssertEqual(saturated.expense.cents, Int64.max, "统计必须饱和而不是溢出成负数")

        // Money 的运算符也必须饱和
        XCTAssertEqual((Money(cents: Int64.max) + Money(cents: 1)).cents, Int64.max)
        XCTAssertEqual((Money(cents: Int64.min) - Money(cents: 1)).cents, Int64.min)

        // 解析层：Int64.max + 1 分（= 92 233 720 368 547 758.08 元）必须返回 nil 而不是崩
        XCTAssertNil(Money.parse("92233720368547758.08"), "超出 Int64 分的金额必须拒绝")
        XCTAssertNil(Money.parse("922337203685477580799"), "整数位溢出必须拒绝")
        XCTAssertNotNil(Money.parse("92233720368547758.07"), "Int64.max 分本身是合法金额")
    }

    // MARK: - B3 备注超长：业务层拒绝；导出层不得崩

    func testB3_OverlongNoteIsRejectedByServiceAndSafeInExport() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let account = try world.firstAccount()

        var draft = EntryDraft(amount: 1000, occurredDay: today.key)
        draft.categoryID = category.id
        draft.accountID = account.id
        draft.note = String(repeating: "长", count: 101)
        XCTAssertThrowsError(try world.env.ledger.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .noteTooLong)
        }

        // 100 字边界是允许的
        draft.note = String(repeating: "长", count: 100)
        XCTAssertNoThrow(try world.env.ledger.create(draft))

        // 导出层：1 万字的备注（绕过业务层直接构造行）不得让 CSV 错列或崩
        let monster = String(repeating: "超长备注,含逗号\n", count: 1_200)  // 10 800 字
        XCTAssertGreaterThan(monster.count, 10_000)
        let rows = [
            ExportRow(
                occurredDay: today.key,
                typeRaw: EntryType.expense.raw,
                amountCents: 1000,
                categoryName: "餐饮",
                accountName: "微信",
                note: monster
            )
        ]
        let csv = ExportService.csv(rows: rows)
        let records = CSVTestParser.records(from: csv)
        XCTAssertEqual(records.count, 2, "1 万字的备注仍然只是一个字段、一行记录")
        XCTAssertEqual(records[1].count, 10, "列数不得变化")
        XCTAssertEqual(records[1][6], monster, "长备注必须逐字还原")
    }

    // MARK: - B4 标题为空 / 全空格：待办与订阅都必须拒绝

    func testB4_EmptyAndBlankTitlesAreRejected() throws {
        let world = try AcceptanceWorld.boot()

        XCTAssertThrowsError(try world.env.todo.create(TodoDraft(title: ""))) { error in
            XCTAssertEqual(error as? TodoError, .titleEmpty)
        }
        XCTAssertThrowsError(try world.env.todo.create(TodoDraft(title: "   \n\t "))) { error in
            XCTAssertEqual(error as? TodoError, .titleEmpty)
        }

        XCTAssertThrowsError(
            try world.env.subscription.create(SubscriptionDraft(name: "   ", amount: 100), today: today)
        ) { error in
            XCTAssertEqual(error as? SubscriptionError, .nameEmpty)
        }

        XCTAssertTrue(try world.env.todo.todos().isEmpty)
        XCTAssertTrue(try world.env.subscription.subscriptions().isEmpty)
    }

    // MARK: - B5 occurredDay 为未来日期：必须拒绝

    func testB5_FutureOccurredDayIsRejected() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let account = try world.firstAccount()

        let tomorrow = DateOnly(Date()).adding(days: 1)
        var draft = EntryDraft(amount: 1000, occurredDay: tomorrow.key)
        draft.categoryID = category.id
        draft.accountID = account.id

        XCTAssertThrowsError(try world.env.ledger.create(draft)) { error in
            XCTAssertEqual(error as? LedgerError, .futureDate)
        }
        XCTAssertEqual(try world.entries().count, 0)

        // 非法日键（2 月 30 日）也必须拒绝
        var invalid = draft
        invalid.occurredDay = 20260230
        XCTAssertThrowsError(try world.env.ledger.create(invalid)) { error in
            XCTAssertEqual(error as? LedgerError, .invalidDate)
        }
    }

    // MARK: - B6 nextBillingDay 极端值：不得死循环

    func testB6_ExtremeNextBillingDayDoesNotHang() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()

        // ① 100 年后：不在扫描候选里，扫描直接空转
        let farFuture = try world.env.subscription.create(
            SubscriptionDraft(name: "百年后", amount: 100, firstBillingDay: 21261121, accountID: account.id),
            today: today
        )
        XCTAssertEqual(farFuture.nextBillingDay, 21261121)
        let emptyReport = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(emptyReport.inserted, 0)
        XCTAssertTrue(emptyReport.isEmpty)

        // ② 1970 年至今（约 670 期）：必须被 24 笔上限截断，而不是无限循环
        let ancient = try world.env.subscription.create(
            SubscriptionDraft(name: "老古董", amount: 100, firstBillingDay: 19700101, accountID: account.id),
            today: today
        )
        let started = Date()
        let cappedReport = world.env.sweep.sweep(today: today, force: true)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(cappedReport.inserted, 24, "单次扫描上限 24 笔（R-SUB-5）")
        XCTAssertEqual(cappedReport.truncatedSubscriptionIDs, [ancient.subscriptionID])
        XCTAssertLessThan(elapsed, 5.0, "24 笔上限必须立即停，不能循环几百期")

        let ancientSub = try XCTUnwrap(
            try world.env.subscription.subscription(id: ancient.subscriptionID)
        )
        XCTAssertGreaterThan(ancientSub.nextBillingDay, 19700101, "被截断后日期也必须推进")

        // ③ 下一次扫描继续从停下的地方推进（允许继续补，但每次不超过 24）
        let second = world.env.sweep.sweep(today: today, force: true)
        XCTAssertLessThanOrEqual(second.inserted, 24, "每次扫描都受同一上限约束")
    }

    // MARK: - B7 订阅金额为 0：只提醒不记账

    func testB7_ZeroAmountSubscriptionAdvancesWithoutWritingEntry() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()

        let created = try world.env.subscription.create(
            SubscriptionDraft(name: "免费试用产品", amount: 0, firstBillingDay: 20260915, accountID: account.id),
            today: today
        )
        let report = world.env.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 0, "金额为 0 不得生成账目（E-9）")
        XCTAssertTrue(report.truncatedSubscriptionIDs.isEmpty)
        XCTAssertEqual(try world.entries().count, 0)

        let subscription = try XCTUnwrap(
            try world.env.subscription.subscription(id: created.subscriptionID)
        )
        XCTAssertEqual(
            subscription.nextBillingDay,
            20261215,
            "虽然没有账目，日期仍必须推进到未来，否则每次扫描都重来一遍"
        )
    }

    // MARK: - B8 同一天 10 个订阅同时扣费：10 笔独立账目（E-6）

    func testB8_TenSubscriptionsDueSameDayCreateTenEntries() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()

        for index in 0..<10 {
            _ = try world.env.subscription.create(
                SubscriptionDraft(
                    name: "订阅\(index)",
                    amount: Int64(index + 1) * 100,
                    firstBillingDay: 20261121,
                    accountID: account.id
                ),
                today: today
            )
        }

        let report = world.env.sweep.sweep(today: today, force: true)
        XCTAssertEqual(report.inserted, 10, "10 个订阅必须生成 10 笔，绝不能合并成一笔")

        let entries = try world.entries()
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(Set(entries.compactMap(\.sourceRefID)).count, 10, "每笔都能独立回溯到自己的订阅")
        XCTAssertEqual(Set(entries.map(\.amount)).count, 10, "金额各自独立，无合并")
        XCTAssertTrue(entries.allSatisfy { $0.occurredDay == 20261121 })

        // 同日合计正确
        let summary = try world.env.ledger.monthSummary(monthKey: 202611)
        XCTAssertEqual(summary.expense.cents, (1...10).reduce(Int64(0)) { $0 + Int64($1) * 100 })
    }

    // MARK: - B9 删除有 500 笔账目的账户：降级归档，绝不级联删账

    func testB9_DeletingAccountWithManyEntriesArchivesInsteadOfCascading() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let accounts = AccountManageViewModel()
        accounts.attach(world.env)

        let accountID = try accounts.create(name: "测试卡", kind: .debit, initialBalanceCents: 0)
        // 用去年的日期：`LedgerService` 拒绝未来日期（校验用的是真实今天），
        // 这里要造的是"500 笔历史账目"，与注入的验收基准日无关。
        for index in 0..<500 {
            try world.manual(
                amount: 100,
                day: 20251101 + Int32(index % 28),
                note: "第\(index)笔",
                categoryID: category.id,
                accountID: accountID
            )
        }
        XCTAssertEqual(try world.entries().count, 500)

        // 用户从别处切到「账户管理」：页面重新加载（真实入口行为）
        accounts.load()

        let preview = try XCTUnwrap(accounts.deletePreview(for: accountID))
        XCTAssertTrue(preview.willArchive)
        XCTAssertEqual(preview.entryCount, 500)

        let outcome = try accounts.delete(id: accountID)
        guard case .archived(let archivedCount) = outcome else {
            return XCTFail("有账目的账户删除必须降级为归档，实际 \(outcome)")
        }
        XCTAssertEqual(archivedCount, 500)

        // 账目一条都不能少
        XCTAssertEqual(try world.entries().count, 500, "归档不得级联删除任何账目")
        XCTAssertTrue(try world.entries().allSatisfy { $0.account?.id == accountID })

        // 账户仍在库里，只是被归档（不再出现在选择器）
        let account = try XCTUnwrap(try world.env.writer.account(id: accountID))
        XCTAssertTrue(account.isArchived)
        XCTAssertFalse(account.isSelectable)
        XCTAssertTrue(accounts.selectableRows.allSatisfy { $0.id != accountID })
    }
}
