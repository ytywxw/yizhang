//
//  Acceptance_TodoTests.swift
//  YiZhangTests / Acceptance
//
//  验收场景 A2（待办完成全流程）+ A12（待办 → 账本联动）。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class Acceptance_TodoTests: XCTestCase {

    private let today = AcceptanceToday.value

    // MARK: - A2 待办完成全流程：勾选 → 取消 → 再勾选 → 改金额 → 一笔账

    func testA2_TodoCompletionLifecycleWritesExactlyOneEntryWithActualAmount() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let category = try world.defaultExpenseCategory()

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

        // ① 勾选完成：状态立刻置 done，并返回"要不要记账"的请求（R-TODO-1/2）
        let request = try world.env.todo.complete(id: todoID, at: today.date)
        XCTAssertTrue(request.needsConfirmation, "带花销的待办必须请求确认")
        XCTAssertEqual(request.suggestedAmount?.cents, 10000, "预填预计金额")
        XCTAssertEqual(request.title, "周末买菜")

        var todo = try XCTUnwrap(try world.env.todo.todo(id: todoID))
        XCTAssertEqual(todo.status, .done)
        XCTAssertNotNil(todo.completedAt)
        XCTAssertNil(todo.linkedEntryID)
        XCTAssertEqual(try world.entries().count, 0, "未确认前不得生成账目（R-TODO-8）")

        // ② 下拽关闭确认条 = UI 回滚（`TodoCompletionSheetViewModel.rollbackCompletionIfNeeded`
        //    执行的就是这一句：reopen(keepEntry: true)）→ 状态回 open，且没有任何账目
        try world.env.todo.reopen(id: todoID, keepEntry: true)
        todo = try XCTUnwrap(try world.env.todo.todo(id: todoID))
        XCTAssertEqual(todo.status, .open, "取消（下拽）必须回到未完成")
        XCTAssertNil(todo.completedAt)
        XCTAssertNil(todo.linkedEntryID)
        XCTAssertEqual(try world.entries().count, 0, "取消后不得留下账目")

        // ③ 再勾一次完成，并把实际金额改成 138 元
        let secondRequest = try world.env.todo.complete(id: todoID, at: today.date)
        let outcome = try world.env.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 13800, categoryID: category.id, accountID: account.id),
            for: secondRequest
        )
        let entryID: UUID
        if case .inserted(let id)? = outcome {
            entryID = id
        } else {
            return XCTFail("「完成并记账」必须生成一笔账，实际结果是 \(String(describing: outcome))")
        }

        let entries = try world.entries()
        XCTAssertEqual(entries.count, 1, "整个流程最终只允许一笔账（幂等键 todo|<id>）")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.amount, 13800, "账目金额是用户确认的实际金额")
        XCTAssertNotEqual(entry.amount, 10000, "绝不能拿预计金额顶替实际金额")
        XCTAssertEqual(entry.type, .expense)
        XCTAssertEqual(entry.source, .todo)
        XCTAssertEqual(entry.sourceRefID, todoID)
        XCTAssertEqual(entry.note, "周末买菜", "备注 = 待办标题（R-TODO-3）")
        XCTAssertEqual(entry.occurredDay, today.key, "发生日 = 完成当天（R-TODO-3）")
        XCTAssertEqual(entry.category?.id, category.id)
        XCTAssertEqual(entry.account?.id, account.id)

        todo = try XCTUnwrap(try world.env.todo.todo(id: todoID))
        XCTAssertEqual(todo.status, .done)
        XCTAssertEqual(todo.linkedEntryID, entryID, "必须回写 linkedEntryID")
        XCTAssertEqual(todo.estimatedAmount, 10000, "改实际金额不得回写预计金额（R-TODO-6）")
        XCTAssertTrue(todo.hasEstimatedAmount)

        // ④ 重复确认不得产生第二笔（幂等键 todo|<id>）
        let duplicate = try world.env.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 13800, categoryID: category.id, accountID: account.id),
            for: secondRequest
        )
        switch duplicate {
        case .skippedDuplicate:
            break
        case .inserted:
            XCTFail("重复确认必须被幂等键挡掉，实际又插了一笔")
        case nil:
            XCTFail("重复确认应当返回「重复跳过」，而不是不记账")
        }
        XCTAssertEqual(try world.entries().count, 1)
    }

    // MARK: - A2b「不记账」出口：待办仍标记完成，账本一分不记

    func testA2b_SkipEntryStillCompletesTodo() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let todoID = try world.env.todo.create(
            TodoDraft(
                title: "同事买单的聚餐",
                dueDay: today.key,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 8800,
                categoryID: category.id,
                accountID: try world.firstAccount().id
            )
        )

        let request = try world.env.todo.complete(id: todoID, at: today.date)
        let outcome = try world.env.todo.confirmCompletion(.skipEntry, for: request)
        XCTAssertNil(outcome, "「不记账」不返回账目")

        let todo = try XCTUnwrap(try world.env.todo.todo(id: todoID))
        XCTAssertEqual(todo.status, .done, "不记账也必须标记完成（R-TODO-4）")
        XCTAssertNil(todo.linkedEntryID)
        XCTAssertEqual(try world.entries().count, 0)
    }

    // MARK: - A2c 无花销待办：勾选即完成，零打扰

    func testA2c_TodoWithoutExpenseCompletesWithoutPrompt() throws {
        let world = try AcceptanceWorld.boot()
        let todoID = try world.env.todo.create(TodoDraft(title: "倒垃圾", dueDay: today.key))

        let request = try world.env.todo.complete(id: todoID, at: today.date)
        XCTAssertFalse(request.needsConfirmation, "无花销待办不得弹确认条（R-TODO-5）")

        let todo = try XCTUnwrap(try world.env.todo.todo(id: todoID))
        XCTAssertEqual(todo.status, .done)
        XCTAssertEqual(try world.entries().count, 0)
    }

    // MARK: - A12 待办 → 账本：分组归类 + 来源徽章 + 详情「来自」可回溯

    func testA12_TodoEntryShowsUpInLedgerWithBadgeAndTraceableSource() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let account = try world.firstAccount()

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

        // ① 账本按日分组里能查到，且落在完成当天
        let monthEntries = try world.entries(inMonth: today.monthKey)
        XCTAssertEqual(monthEntries.count, 1)

        let row = EntryRowModel(entry: try XCTUnwrap(monthEntries.first))
        XCTAssertEqual(row.source, .todo)
        XCTAssertTrue(row.source.needsBadge, "待办来源必须有 ✅ 徽章")
        XCTAssertEqual(row.day, today)
        XCTAssertEqual(row.amount.cents, 13800)
        XCTAssertEqual(row.note, "周末买菜")
        XCTAssertEqual(row.categoryName, category.displayName)

        // ② 详情页「来自」能回溯到待办
        let todo = try XCTUnwrap(try world.env.todo.todo(id: todoID))
        let detail = EntryDetailModel(
            entry: try XCTUnwrap(monthEntries.first),
            sourceTitle: todo.title,
            isSourceDeleted: false
        )
        XCTAssertEqual(detail.source, .todo)
        XCTAssertEqual(detail.sourceTitle, "周末买菜")
        XCTAssertFalse(detail.isSourceDeleted)

        // ③ 首页概览卡与分组头同源
        let home = LedgerHomeViewModel(today: today)
        home.attach(world.env)
        XCTAssertEqual(home.overview.expense.cents, 13800)
        XCTAssertEqual(home.groups.count, 1)
        XCTAssertEqual(home.groups[0].expense.cents, 13800)

        // ④ 删除待办不删账目（R-TODO-DEL），账目「来自」退化成「来源已删除」
        try world.env.todo.delete(id: todoID)
        XCTAssertEqual(try world.entries().count, 1, "删除待办不得删除它生成的账目")
        let orphan = try XCTUnwrap(try world.entries().first)
        XCTAssertEqual(orphan.source, .todo)
        let stillThere = try world.env.todo.todo(id: todoID)
        XCTAssertNil(stillThere, "待办已被删除，按 id 应查不到")
        let orphanDetail = EntryDetailModel(entry: orphan, sourceTitle: nil, isSourceDeleted: true)
        XCTAssertTrue(orphanDetail.isSourceDeleted)
        XCTAssertNil(orphanDetail.sourceTitle)
    }

    // MARK: - 撤销完成：保留 / 删除关联账目两条出口

    func testA2d_ReopenWithKeepEntryVsDeleteEntry() throws {
        let world = try AcceptanceWorld.boot()
        let category = try world.defaultExpenseCategory()
        let account = try world.firstAccount()

        // 保留账目
        let keepID = try world.env.todo.create(
            TodoDraft(
                title: "加油", dueDay: today.key, hasExpense: true,
                hasEstimatedAmount: true, estimatedAmount: 20000,
                categoryID: category.id, accountID: account.id
            )
        )
        let keepRequest = try world.env.todo.complete(id: keepID, at: today.date)
        _ = try world.env.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 20000, categoryID: category.id, accountID: account.id),
            for: keepRequest
        )
        try world.env.todo.reopen(id: keepID, keepEntry: true)
        let keptTodo = try XCTUnwrap(try world.env.todo.todo(id: keepID))
        XCTAssertEqual(keptTodo.status, .open)
        XCTAssertNil(keptTodo.linkedEntryID, "保留账目后必须断开 linkedEntryID，否则再次完成不会弹确认")
        XCTAssertEqual(try world.entries().count, 1, "「保留账目」不得删账")

        // 一并删除（软删）
        let deleteID = try world.env.todo.create(
            TodoDraft(
                title: "退货", dueDay: today.key, hasExpense: true,
                hasEstimatedAmount: true, estimatedAmount: 5000,
                categoryID: category.id, accountID: account.id
            )
        )
        let deleteRequest = try world.env.todo.complete(id: deleteID, at: today.date)
        _ = try world.env.todo.confirmCompletion(
            CompletionConfirmation(amountCents: 5000, categoryID: category.id, accountID: account.id),
            for: deleteRequest
        )
        XCTAssertEqual(try world.entries().count, 2)

        try world.env.todo.reopen(id: deleteID, keepEntry: false)
        XCTAssertEqual(try world.entries().count, 1, "「一并删除」后账目不应出现在列表里")
        XCTAssertEqual(try world.entries(includeDeleted: true).count, 2, "删除是软删，记录仍在库里")
    }
}
