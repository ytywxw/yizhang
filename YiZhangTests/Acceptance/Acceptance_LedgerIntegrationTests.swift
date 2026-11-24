//
//  Acceptance_LedgerIntegrationTests.swift
//  YiZhangTests / Acceptance
//
//  验收场景 A9（分类删除迁移）、A11（订阅 → 账本）、A13（三模块总额一致性）。
//  这三条是本产品"一件事，一笔账"的核心卖点，也是跨模块最容易出现口径不一致的地方。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class Acceptance_LedgerIntegrationTests: XCTestCase {

    private let today = AcceptanceToday.value

    // MARK: - A9 删除自定义分类：3 笔账全部迁移，且无孤儿引用

    func testA9_DeletingCustomCategoryMigratesAllEntries() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()

        let categories = CategoryManageViewModel()
        categories.attach(world.env)

        let customID = try categories.create(
            name: "宠物用品",
            type: .expense,
            iconName: "pawprint",
            colorHex: "#8E44AD"
        )
        for day in [Int32(20261110), 20261112, 20261115] {
            try world.manual(amount: 3600, day: day, note: "猫粮", categoryID: customID, accountID: account.id)
        }
        XCTAssertEqual(try world.entries().count, 3)
        XCTAssertTrue(try world.entries().allSatisfy { $0.category?.id == customID })

        // 用户从账本切到「我的 → 分类管理」：页面重新加载（真实入口行为）
        categories.load()

        let target = try XCTUnwrap(try world.expenseCategories().first { $0.id != customID })
        let preview = try XCTUnwrap(categories.deletePreview(for: customID))
        guard case .requiresMigration(_, let count) = preview else {
            return XCTFail("有账目的自定义分类，删除前必须先要求迁移（R-CAT-2）")
        }
        XCTAssertEqual(count, 3)

        let outcome = try categories.delete(id: customID, migratingTo: target.id)
        guard case .migrated(let migrated) = outcome else {
            return XCTFail("应返回「已迁移」，实际 \(outcome)")
        }
        XCTAssertEqual(migrated, 3)

        // 3 笔账的分类都变成目标分类
        let entries = try world.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(
            entries.allSatisfy { $0.category?.id == target.id },
            "迁移后所有账目的分类必须是目标分类"
        )

        // 原分类已删除
        let removed = try world.env.readContext.fetch(QueryDescriptors.category(id: customID)).first
        XCTAssertNil(removed)

        // 无孤儿引用（R-CAT-2 的底线：不允许产生无分类账目）
        let report = try Diagnostics.run(in: world.container)
        XCTAssertEqual(report.orphanReferenceCount, 0, "不允许出现无分类/无账户的账目")
        XCTAssertEqual(report.duplicateUniqueKeyEntries.count, 0)
        XCTAssertEqual(report.negativeAmountCount, 0)

        // 迁移后统计口径不丢钱
        let stats = StatisticsCalculator.totals(try world.lites(), range: .thisMonth, today: today)
        XCTAssertEqual(stats.expense.cents, 3600 * 3)
    }

    // MARK: - A11 订阅 → 账本：按日归类、来源徽章、详情可回溯

    func testA11_SubscriptionEntryShowsUpInLedgerWithBadgeAndTraceableSource() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let created = try world.env.subscription.create(
            SubscriptionDraft(
                name: "视频会员",
                amount: 2500,
                firstBillingDay: 20261115,
                accountID: account.id
            ),
            today: today
        )
        XCTAssertEqual(world.env.sweep.sweep(today: today, force: true).inserted, 1)

        // ① 账本按日分组：落在应扣日那一天
        let monthEntries = try world.entries(inMonth: 202611)
        XCTAssertEqual(monthEntries.count, 1)
        let entry = try XCTUnwrap(monthEntries.first)
        XCTAssertEqual(entry.occurredDay, 20261115)

        let row = EntryRowModel(entry: entry)
        XCTAssertEqual(row.source, .subscription)
        XCTAssertTrue(row.source.needsBadge, "订阅来源必须有 🔁 徽章")
        XCTAssertEqual(row.day, DateOnly(key: 20261115))
        XCTAssertEqual(row.amount.cents, 2500)
        XCTAssertEqual(row.categoryName, "订阅服务", "默认分类是「订阅服务」（R-CAT-4）")

        // ② 详情页「来自」能回溯到订阅
        let subscription = try XCTUnwrap(
            try world.env.subscription.subscription(id: created.subscriptionID)
        )
        let detail = EntryDetailModel(entry: entry, sourceTitle: subscription.displayName, isSourceDeleted: false)
        XCTAssertEqual(detail.source, .subscription)
        XCTAssertEqual(detail.sourceTitle, "视频会员")
        XCTAssertFalse(detail.isSourceDeleted)

        // ③ 首页概览卡与分组同源
        let home = LedgerHomeViewModel(today: today)
        home.attach(world.env)
        XCTAssertEqual(home.overview.expense.cents, 2500)
        XCTAssertEqual(home.groups.count, 1)
        XCTAssertEqual(home.groups[0].day, DateOnly(key: 20261115))
        XCTAssertEqual(home.groups[0].expense.cents, 2500)

        // ④ 删除订阅（E-11）后账目保留、来源变「订阅已删除」
        try world.env.subscription.delete(id: created.subscriptionID)
        XCTAssertEqual(try world.entries().count, 1, "删除订阅不得删除历史账目")
        let orphan = try XCTUnwrap(try world.entries().first)
        XCTAssertEqual(orphan.source, .subscription)
        let missingSource = try world.env.readContext
            .fetch(QueryDescriptors.subscription(id: created.subscriptionID))
            .first
        XCTAssertNil(missingSource)
    }

    // MARK: - A13 三模块总额一致性：手工 + 订阅 + 待办 == 首页概览卡「本月支出」

    func testA13_ThreeModuleTotalsMatchHomeOverviewAndStatistics() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let category = try world.defaultExpenseCategory()

        // ① 手工账：¥28.00
        try world.manual(amount: 2800, day: 20261110, note: "午饭", categoryID: category.id, accountID: account.id)

        // ② 订阅账：¥25.00（11-15 应扣）
        _ = try world.env.subscription.create(
            SubscriptionDraft(
                name: "视频会员",
                amount: 2500,
                firstBillingDay: 20261115,
                accountID: account.id
            ),
            today: today
        )
        XCTAssertEqual(world.env.sweep.sweep(today: today, force: true).inserted, 1)

        // ③ 待办账：¥138.00（今天完成）
        let todoID = try world.env.todo.create(
            TodoDraft(
                title: "周末买菜",
                dueDay: today.key,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 10000,
                categoryID: category.id,
                accountID: account.id
            )
        )
        let request = try world.env.todo.complete(id: todoID, at: today.date)
        _ = try world.env.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 13800, categoryID: category.id, accountID: account.id),
            for: request
        )

        // ④ 转账：¥50.00（账户间搬钱，绝不能进支出）
        try world.transfer(amount: 5000, day: 20261112)

        let expected: Int64 = 2800 + 2500 + 13800

        // 来源构成（转账的 source 也是 manual，所以手工来源要按类型再筛一次）
        XCTAssertEqual(try world.entries(ofSource: .manual).filter { $0.type == .expense }.count, 1)
        XCTAssertEqual(try world.entries(ofSource: .manual).filter { $0.type == .transfer }.count, 1)
        XCTAssertEqual(try world.entries(ofSource: .subscription).count, 1)
        XCTAssertEqual(try world.entries(ofSource: .todo).count, 1)

        // 服务层汇总
        let summary = try world.env.ledger.monthSummary(monthKey: 202611)
        XCTAssertEqual(summary.expense.cents, expected, "服务层月度汇总")
        XCTAssertEqual(summary.income.cents, 0)

        // 首页概览卡（ViewModel 真实装配）
        let home = LedgerHomeViewModel(today: today)
        home.attach(world.env)
        XCTAssertEqual(home.overview.expense.cents, expected, "首页概览卡「本月支出」")
        XCTAssertEqual(home.allGroups.count, 4, "11/10、11/12、11/15、11/21 共四天分组")

        // 分组头合计必须与概览卡相等（同源，不允许自相矛盾）
        let groupTotal = home.allGroups.reduce(Int64(0)) { $0 + $1.expense.cents }
        XCTAssertEqual(groupTotal, expected, "分组头合计 == 概览卡")
        XCTAssertEqual(home.entryCount, 4, "首页应显示 4 笔（含转账）")

        // 统计页口径
        let stats = StatisticsCalculator.totals(try world.lites(), range: .thisMonth, today: today)
        XCTAssertEqual(stats.expense.cents, expected, "统计页本月支出")
        XCTAssertEqual(stats.income.cents, 0)

        // 转账不计入任何一处
        XCTAssertFalse(
            [summary.expense.cents, home.overview.expense.cents, stats.expense.cents].contains(expected + 5000),
            "转账不得计入支出（R-IN-5）"
        )
    }
}
