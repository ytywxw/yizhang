//
//  TemplateChipsUITests.swift
//  YiZhangUITests
//
//  职责：记账面板模板 chips 的三件事 —— 渲染、点击填入、无模板时整行不渲染。
//
//  断言点为什么是 `entry.note` 的值：`EntryViewModel.applyTemplate` 的第 ⑤ 步
//  **无条件** `note = template.note`（含"把备注改回空"），是这条路径上唯一一个
//  "一定会被模板改写、且不改标识符就能读到"的字段。金额那条路要读 `AmountDisplayView`
//  的文本，而它没有标识符——为测试往 app 代码里加一个"万一以后要用"的标识符属于投机性改动。
//

import XCTest

final class TemplateChipsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 渲染

    func testTemplateChips_AllSeededTemplatesRender() {
        let app = launchEntrySheet(injectTemplates: true)

        XCTAssertTrue(
            element(app, "entry.template.row").waitForExistence(timeout: 10),
            "模板 chips 整行没渲染。可能是模板种子没生效。\n\(app.debugDescription)"
        )

        for name in ["午饭", "通勤", "咖啡"] {
            XCTAssertTrue(
                app.buttons["entry.template.\(name)"].exists,
                "缺 chip「\(name)」。种子里的模板名与断言不一致时会走到这里。\n\(app.debugDescription)"
            )
        }
    }

    // MARK: - 点击填入

    func testTemplateChip_TapFillsNote() {
        let app = launchEntrySheet(injectTemplates: true)

        let note = noteField(app)
        XCTAssertTrue(
            note.waitForExistence(timeout: 10),
            "找不到备注输入框。\n\(app.debugDescription)"
        )

        let lunch = app.buttons["entry.template.午饭"]
        XCTAssertTrue(lunch.waitForExistence(timeout: 10), "缺 chip「午饭」。")
        lunch.tap()

        let lunchNote = NSPredicate(format: "value == %@", "模板备注-午饭")
        let lunchExpectation = XCTNSPredicateExpectation(predicate: lunchNote, object: note)
        XCTAssertEqual(
            XCTWaiter.wait(for: [lunchExpectation], timeout: 10), .completed,
            "点「午饭」后备注不是「模板备注-午饭」，实际：\(String(describing: note.value))"
        )

        // 再点另一个：模板是"整套表单"，后点的必须整体覆盖前一个，而不是拼接。
        let commute = app.buttons["entry.template.通勤"]
        XCTAssertTrue(commute.waitForExistence(timeout: 10), "缺 chip「通勤」。")
        commute.tap()

        let commuteNote = NSPredicate(format: "value == %@", "模板备注-通勤")
        let commuteExpectation = XCTNSPredicateExpectation(predicate: commuteNote, object: note)
        XCTAssertEqual(
            XCTWaiter.wait(for: [commuteExpectation], timeout: 10), .completed,
            "点「通勤」后备注不是「模板备注-通勤」，实际：\(String(describing: note.value))"
        )
    }

    // MARK: - 空态

    func testTemplateChips_RowHiddenWhenNoTemplates() {
        let app = launchEntrySheet(injectTemplates: false)

        // 先证明面板真的开了，否则"chips 不存在"可以因为"整个面板没开"而假绿。
        XCTAssertTrue(
            app.buttons["entry.save"].exists,
            "记账面板没打开，这条用例证明不了任何事。\n\(app.debugDescription)"
        )

        XCTAssertFalse(
            element(app, "entry.template.row").waitForExistence(timeout: 3),
            "没有模板时 chips 整行不该渲染（`TemplateChipsRow` 的 `if !templates.isEmpty`）。"
        )
        XCTAssertFalse(
            app.buttons["entry.template.午饭"].exists,
            "没有模板时不该出现任何 chip。"
        )
    }

    // MARK: - 启动

    /// 取备注输入框。
    ///
    /// `entry.note` 是 `TextField(axis: .vertical)`，在无障碍树里报成 `textField` 还是
    /// `textView` 会随系统版本变；先按可输入的 `textField` 找，找不到再退回只按标识符找。
    private func noteField(_ app: XCUIApplication) -> XCUIElement {
        let asTextField = app.textFields["entry.note"]
        if asTextField.waitForExistence(timeout: 5) {
            return asTextField
        }
        return element(app, "entry.note")
    }

    /// 打开记账面板。面板是 sheet，合成不出"点新建"的动作，只能靠 `-YIZHANG_DEMO_OPEN entry`。
    private func launchEntrySheet(injectTemplates: Bool) -> XCUIApplication {
        let app = XCUIApplication.yizhang(
            tab: "ledger",
            open: "entry",
            flags: injectTemplates ? [DemoFlag.templates] : []
        )
        XCTAssertTrue(
            app.buttons["entry.save"].waitForExistence(timeout: 20),
            "记账面板没打开。\n\(app.debugDescription)"
        )
        return app
    }
}
