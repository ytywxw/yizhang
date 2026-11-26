//
//  DialogContainerProbeUITests.swift
//  YiZhangUITests
//
//  职责：**spike 专用**——只回答一个问题：`confirmationDialog` 的按钮在 XCUITest 里
//  到底挂在 `app.sheets`、`app.alerts`，还是两个都不是。
//
//  为什么必须实测而不是照惯例写：SwiftUI 的 `confirmationDialog` 底层是
//  `UIAlertController(style: .actionSheet)`，但"从 sheet 内部弹出"和"从根视图弹出"
//  在呈现栈里不是同一层；两者挂到不同容器上时，按错误容器写断言会得到"元素不存在"，
//  这种失败和"按钮压根没渲染"长得一模一样，极容易被误判成产品 bug。
//
//  两个用例分别覆盖两种来源：
//  - `testDialogHost_ListRoot_DeleteRecord`：列表页根视图弹出（已完成行的「⋯」）；
//  - `testDialogHost_EditorSheet_DeleteOccurrence`：编辑页（本身就是 sheet）内部弹出。
//
//  输出：每个用例都会 `print` 一行 `PROBE[...]`，测试结果里带各容器的真实计数。
//  这一行是 spike 的交付物之一，不要删。
//

import XCTest

final class DialogContainerProbeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 用例 1：列表页根视图弹出

    func testDialogHost_ListRoot_DeleteRecord() {
        let app = launchTodoApp()

        // 已完成分组的行默认是折叠的（`isCompletedCollapsed = true`）；
        // 启动参数里的 `todo-completed-expanded` 已经替我们展开了，不需要手点。
        // 同一标识符在无障碍树里可能命中多个元素，`.firstMatch` 取第一个即可 ——
        // 这里只关心「能点到那一行的菜单」，不关心树里到底有几个。
        let menuID = "todo.row.menu.续费会员.done"
        let menuMatches = app.buttons.matching(identifier: menuID)
        XCTAssertTrue(
            menuMatches.firstMatch.waitForExistence(timeout: 15),
            "找不到已完成重复行的「⋯」。可能是种子里没有「已完成 + 重复」的待办，或已完成分组没展开。\n\(app.debugDescription)"
        )
        print("COUNT[list-root] \"\(menuID)\" 命中 \(menuMatches.count) 个元素")
        menuMatches.firstMatch.tap()

        let menuItem = app.buttons["删除这条记录"]
        XCTAssertTrue(
            menuItem.waitForExistence(timeout: 10),
            "「⋯」菜单里没有「删除这条记录」。\n\(app.debugDescription)"
        )
        menuItem.tap()

        probe(
            app,
            dialogTitle: "删除这条记录？",
            actionLabel: "删除这条记录",
            context: "list-root"
        )

        // 刻意不在这里点「取消」收尾：实测列表页根视图弹出的这张弹层，
        // 它的取消按钮在无障碍树里**没有 label**（`app.buttons["取消"]` 查不到，
        // 只剩几个空 label 的 Button）。这是容器探测之外的另一条事实，
        // 正式用例不能靠 label 关弹层。spike 只需要把容器测出来，用完直接结束用例。
    }

    // MARK: - 用例 2：编辑页（sheet 内部）弹出

    func testDialogHost_EditorSheet_DeleteOccurrence() {
        let app = launchTodoApp()

        // 未完成 + 重复的行：点整行进编辑页（已完成的行点进去是「撤销完成」弹层，不是编辑页）
        let row = app.otherElements["todo.row.每天喝水.open"]
        if row.waitForExistence(timeout: 15) {
            row.tap()
        } else {
            let title = app.staticTexts["每天喝水"]
            XCTAssertTrue(
                title.waitForExistence(timeout: 5),
                "找不到「每天喝水」这一行。重复待办种子可能没生效。\n\(app.debugDescription)"
            )
            title.tap()
        }

        let deleteButton = app.buttons["todoEditor.delete"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 15),
            "编辑页没有出现删除卡片（`todoEditor.delete`）。\n\(app.debugDescription)"
        )

        // 危险操作卡片在编辑页最下方，可能不在首屏 → 滑到可点为止
        var scrolls = 0
        while !deleteButton.isHittable && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(deleteButton.isHittable, "删除卡片滚了 \(scrolls) 次仍不可点。")
        deleteButton.tap()

        probe(
            app,
            dialogTitle: "删除还是停止重复？",
            actionLabel: "删除这一期",
            context: "editor-sheet"
        )

        // 同样不做「取消」收尾：此刻屏幕上有两层（编辑页 sheet + 弹层），
        // `app.buttons["取消"]` 命中的是编辑页自己那个，点了会连 sheet 一起关掉，
        // "点了没崩"看起来像通过、其实验的是另一件事。spike 只回答容器问题。
    }

    // MARK: - 探针

    /// 把弹层按钮所在的容器实测出来并打印。
    ///
    /// 判据刻意用 `exists` 而不是 `isHittable`：这里只问"挂在哪个容器"，不问"能不能点"。
    /// 两件事分开验证，失败时才能定位是哪一步坏了。
    private func probe(
        _ app: XCUIApplication,
        dialogTitle: String,
        actionLabel: String,
        context: String
    ) {
        XCTAssertTrue(
            app.staticTexts[dialogTitle].waitForExistence(timeout: 10),
            "[\(context)] 弹层标题「\(dialogTitle)」没出现——弹层可能压根没弹。\n\(app.debugDescription)"
        )

        let sheetsCount = app.sheets.count
        let alertsCount = app.alerts.count
        let inSheets = app.sheets.buttons[actionLabel].exists
        let inAlerts = app.alerts.buttons[actionLabel].exists
        let inAppButtons = app.buttons[actionLabel].exists

        let host: String
        if inAlerts {
            host = "alerts"
        } else if inSheets {
            host = "sheets"
        } else if inAppButtons {
            host = "app.buttons（不在 alerts / sheets 之下）"
        } else {
            host = "未找到"
        }

        print(
            "PROBE[\(context)] action=\(actionLabel) host=\(host) "
            + "sheets.count=\(sheetsCount) alerts.count=\(alertsCount) "
            + "inAlerts=\(inAlerts) inSheets=\(inSheets) inAppButtons=\(inAppButtons)"
        )

        XCTAssertTrue(
            inAppButtons,
            "[\(context)] 按钮「\(actionLabel)」在任何容器里都查不到——这一条路走不通，需要停手上报。\n\(app.debugDescription)"
        )
    }

    // MARK: - 启动

    private func launchTodoApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-YIZHANG_INITIAL_TAB", "todo",
            "-YIZHANG_UITEST", "1",
            "-YIZHANG_DEMO_TODOS_REPEAT", "1",
            // 单值 key：这里只能用这一个值（互斥会覆盖，见 `TodoListView.openDemoScreenIfRequested`）
            "-YIZHANG_DEMO_OPEN", "todo-completed-expanded"
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["todo.add"].waitForExistence(timeout: 20),
            "待办页没起来。\n\(app.debugDescription)"
        )
        return app
    }
}
