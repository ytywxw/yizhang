//
//  TodoDeleteDialogUITests.swift
//  YiZhangUITests
//
//  职责：待办删除确认弹层的**三个分支**在 UI 上是否真的渲染成了对应的样子。
//
//  为什么都从编辑页进（`todoEditor.delete`）而不是列表页的「⋯」：
//  编辑页用**一个** `confirmationDialog` + 条件按钮覆盖三种删除形态
//  （`TodoEditorView.swift` 的 `deleteDialogTitle` / 三个 `if` 分支），
//  标题和按钮组合随这条待办的实际状态切换 —— 这正是最值得钉住的地方。
//  列表页的「⋯」背后是三个独立弹层，且已完成行的入口在列表页被"撤销完成"挡住了。
//
//  断言容器一律 `app.sheets`：实测（spike）两种来源的弹层都挂在 `app.sheets`，
//  `app.alerts` 恒为 0。
//
//  收尾一律点 destructive 按钮直接结束用例，**不点「取消」**：
//  列表页那张弹层的「取消」在无障碍树里没有 label，而且每条用例都是全新启动 +
//  全新内存库，弹层留在屏幕上不影响任何后续用例。反过来，为了"把弹层关掉"去点正文
//  或坐标点击是最经典的偶发红来源，这里明确不做。
//

import XCTest

final class TodoDeleteDialogUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 未完成 + 重复：两个选项都在

    func testDeleteDialog_OpenRepeating_OffersBothScopeOptions() {
        let app = launchTodoList()
        openEditor(app, title: "每天喝水")
        tapDeleteCard(app)

        assertDialog(title: "删除还是停止重复？", in: app)
        XCTAssertTrue(
            app.sheets.buttons["删除这一期"].exists,
            "重复待办的删除弹层缺「删除这一期」。\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.sheets.buttons["删除此次及以后"].exists,
            "重复待办的删除弹层缺「删除此次及以后」。\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.sheets.buttons["删除"].exists,
            "重复待办不该出现单选项「删除」——那会让用户以为一次点击就停掉了整个系列。"
        )
    }

    // MARK: - 未完成 + 重复：删除这一期 → 下一期还在

    func testDeleteDialog_DeleteCurrentOccurrence_KeepsSeriesAlive() {
        let app = launchTodoList()

        // 「今天要办 N 件」只数今天分组，不含订阅派生项（R-MIX-3）。
        // 种子给今天两条（每天喝水 / 倒垃圾），删掉「这一期」后应当剩一条。
        // 用这个数字而不是"分组标题"来判断，是因为分组标题会随星期漂移
        // （`today+3` 在周日会跨到下一周），那是自找的偶发红。
        let summary = element(app, "todo.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "找不到「今天要办 N 件」摘要行。")
        waitForLabel(of: summary, contains: "今天要办 2 件")

        openEditor(app, title: "每天喝水")
        tapDeleteCard(app)
        assertDialog(title: "删除还是停止重复？", in: app)
        app.sheets.buttons["删除这一期"].tap()

        XCTAssertTrue(
            app.buttons["todo.add"].waitForExistence(timeout: 15),
            "删除后没有回到列表页。\n\(app.debugDescription)"
        )
        waitForLabel(of: summary, contains: "今天要办 1 件",
                     message: "今天分组的那一条应该已经删掉。")

        // 关键断言：这一期没了，但系列还在 —— 下一期（明天）必须仍在列表里。
        XCTAssertTrue(
            element(app, "todo.row.每天喝水.open").waitForExistence(timeout: 10),
            "「删除这一期」把整个系列删掉了：下一期没出现。\n\(app.debugDescription)"
        )
    }

    // MARK: - 未完成 + 重复：删除此次及以后 → 标题彻底消失

    func testDeleteDialog_DeleteThisAndFollowing_StopsSeries() {
        let app = launchTodoList()
        openEditor(app, title: "每天喝水")
        tapDeleteCard(app)
        assertDialog(title: "删除还是停止重复？", in: app)
        app.sheets.buttons["删除此次及以后"].tap()

        XCTAssertTrue(
            app.buttons["todo.add"].waitForExistence(timeout: 15),
            "删除后没有回到列表页。\n\(app.debugDescription)"
        )
        waitForDisappearance(
            of: element(app, "todo.row.每天喝水.open"),
            message: "「删除此次及以后」之后不该再有这个标题的任何一期。"
        )
    }

    // MARK: - 未完成 + 非重复：只有一个「删除」

    func testDeleteDialog_OpenPlain_OffersSingleDelete() {
        let app = launchTodoList()
        openEditor(app, title: "倒垃圾")
        tapDeleteCard(app)

        assertDialog(title: "删除这条待办？", in: app)
        XCTAssertTrue(
            app.sheets.buttons["删除"].exists,
            "非重复待办的删除弹层缺「删除」。\n\(app.debugDescription)"
        )
        XCTAssertFalse(
            app.sheets.buttons["删除这一期"].exists,
            "非重复待办不该出现「删除这一期」——它没有「这一期」和「下一期」之分。"
        )
    }

    func testDeleteDialog_OpenPlain_ConfirmRemovesRow() {
        let app = launchTodoList()
        openEditor(app, title: "倒垃圾")
        tapDeleteCard(app)
        assertDialog(title: "删除这条待办？", in: app)
        app.sheets.buttons["删除"].tap()

        XCTAssertTrue(
            app.buttons["todo.add"].waitForExistence(timeout: 15),
            "删除后没有回到列表页。\n\(app.debugDescription)"
        )
        waitForDisappearance(of: element(app, "todo.row.倒垃圾.open"))
    }

    // MARK: - 已完成 + 重复：唯一入口是「账目详情 → 来自」

    func testDeleteDialog_DoneRepeating_ReachableFromEntryDetail() {
        // 账本页启动：种子里「续费会员」完成时走真实 `complete` + `confirmCompletion`
        // 写了一笔账，所以账本里必然有且只有这一行。
        let app = XCUIApplication.yizhang(tab: "ledger", flags: [DemoFlag.repeatingTodos])

        let ledgerRow = firstLedgerRow(app)
        XCTAssertTrue(
            ledgerRow.waitForExistence(timeout: 20),
            "账本列表里没有待办产出的那笔账目。\n\(app.debugDescription)"
        )
        ledgerRow.tap()

        XCTAssertTrue(
            element(app, "detail.root").waitForExistence(timeout: 15),
            "没进账目详情页。\n\(app.debugDescription)"
        )
        // 「来自」这一行只在 `sourceRefID` 存在时才是可点的（否则是纯文本）。
        let source = app.buttons["detail.source"]
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "详情页没有可点的「来自」入口，删记录这条路走不通。\n\(app.debugDescription)"
        )
        source.tap()

        XCTAssertTrue(
            element(app, "todo.editor").waitForExistence(timeout: 15),
            "「来自」没有打开待办编辑页。\n\(app.debugDescription)"
        )
        tapDeleteCard(app)

        assertDialog(title: "删除这条记录？", in: app)
        XCTAssertTrue(
            app.sheets.buttons["删除这条记录"].exists,
            "已完成记录的弹层缺「删除这条记录」。\n\(app.debugDescription)"
        )
        // 正文必须说清"重复设置不会被修改"，否则用户会以为删一条等于停掉订阅式重复。
        let message = app.sheets.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "重复设置不会被修改"))
            .firstMatch
        XCTAssertTrue(
            message.waitForExistence(timeout: 10),
            "弹层正文没说清「重复设置不会被修改」。\n\(app.debugDescription)"
        )
    }

    // MARK: - 公共步骤

    private func launchTodoList() -> XCUIApplication {
        let app = XCUIApplication.yizhang(tab: "todo", flags: [DemoFlag.repeatingTodos])
        XCTAssertTrue(
            app.buttons["todo.add"].waitForExistence(timeout: 20),
            "待办页没起来。\n\(app.debugDescription)"
        )
        return app
    }

    /// 点未完成行 → 进编辑页。
    ///
    /// 只走未完成行：已完成的行点进去是「撤销这个待办的完成？」弹层（`open(_:)` 里
    /// `if row.isDone` 先分支），不是编辑页。
    private func openEditor(_ app: XCUIApplication, title: String) {
        let row = element(app, "todo.row.\(title).open")
        XCTAssertTrue(
            row.waitForExistence(timeout: 20),
            "找不到未完成行「\(title)」。种子没生效，或者这一行不在首屏。\n\(app.debugDescription)"
        )
        row.tap()

        XCTAssertTrue(
            element(app, "todo.editor").waitForExistence(timeout: 15),
            "点「\(title)」没打开编辑页。\n\(app.debugDescription)"
        )
    }

    /// 点编辑页最下方的「删除待办」危险卡片。
    ///
    /// 滚动条件是 `!isHittable` 而不是 `!exists`：卡片在 roll 里已经存在，
    /// 只是可能被挤到屏幕外，用 `exists` 会立刻退出循环然后 tap 失败。
    private func tapDeleteCard(_ app: XCUIApplication) {
        let deleteButton = app.buttons["todoEditor.delete"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 15),
            "编辑页没有删除卡片（`todoEditor.delete`）。这条待办可能不是编辑模式。\n\(app.debugDescription)"
        )

        var scrolls = 0
        while !deleteButton.isHittable && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(
            deleteButton.isHittable,
            "删除卡片滚了 \(scrolls) 次仍不可点。\n\(app.debugDescription)"
        )
        deleteButton.tap()
    }

    /// 弹层标题出现即算弹出来了；容器断言交给调用方用 `app.sheets.buttons[...]`。
    private func assertDialog(title: String, in app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts[title].waitForExistence(timeout: 10),
            "删除确认弹层没出现（期望标题「\(title)」）。\n\(app.debugDescription)"
        )
    }

    /// 账本列表里那一行。
    ///
    /// 行标识符是 `ledger.row.<uuid>`，uuid 每次内存库启动都不同，所以按前缀取。
    /// 兜底用 label 里必然出现的备注文本 —— 万一标识符被合并到外层 Button 上，
    /// 前缀查询会落空，这时至少还有一条路能走。
    private func firstLedgerRow(_ app: XCUIApplication) -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ledger.row."))
            .firstMatch
        if byIdentifier.waitForExistence(timeout: 15) {
            return byIdentifier
        }
        return app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "续费会员"))
            .firstMatch
    }
}
