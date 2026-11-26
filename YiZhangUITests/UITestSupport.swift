//
//  UITestSupport.swift
//  YiZhangUITests
//
//  职责：UI 用例共用的启动参数拼装与元素查询。
//
//  三条纪律（踩过的坑写在这里，别在用例里重犯）：
//  ① **一律带 `-YIZHANG_UITEST 1`**：每个用例都是全新内存库，用例之间互相看不到数据，
//     也就不需要"跑之前先清库"这种会互相踩的准备工作。
//  ② **只开本次用得到的种子开关**：多开一个种子就多一份"改种子就红"的债，
//     而且会让屏幕上的行数变多、断言变脆。
//  ③ **查询只按标识符 / label，不做坐标点击、不按行序取元素**（`element(boundBy:)`）。
//     按行序取在种子顺序一改就全错，第二个维护的人会直接把测试删掉。
//

import XCTest

/// 演示种子的启动参数键。值一律传 `"1"`。
enum DemoFlag {
    /// 3 个记账模板（午饭 / 通勤 / 咖啡），记账面板的 chips 靠它才有内容。
    static let templates = "YIZHANG_DEMO_TEMPLATES"
    /// 3 条待办：未完成+重复 / 已完成+重复+带花销 / 未完成+非重复。
    static let repeatingTodos = "YIZHANG_DEMO_TODOS_REPEAT"
}

extension XCUIApplication {

    /// 启动一账。
    ///
    /// - Parameters:
    ///   - tab: 首屏 Tab（`todo` / `ledger` / `subscription` / `me`）。
    ///   - open: `-YIZHANG_DEMO_OPEN` 的值。这是**单值** key，各页面互斥，只能传一个。
    ///   - flags: 需要打开的演示种子开关。
    static func yizhang(tab: String, open: String? = nil, flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = [
            "-YIZHANG_INITIAL_TAB", tab,
            "-YIZHANG_UITEST", "1"
        ]
        if let open {
            arguments += ["-YIZHANG_DEMO_OPEN", open]
        }
        for flag in flags {
            // 必须带前导 `-`：app 侧是按 `UserDefaults.standard.bool(forKey:)` 读的，
            // 参数表里少了这个横杠，就是一条谁都读不到的裸字符串 —— 种子静默不生效，
            // 用例会以"元素找不到"的形式红，看起来像 app 坏了。
            arguments += ["-\(flag)", "1"]
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }
}

/// 按标识符取元素，**不限定元素类型**。
///
/// 为什么不用 `app.buttons[...]` / `app.otherElements[...]`：SwiftUI 把同一个
/// `.accessibilityIdentifier` 挂到 Button / Other / StaticText 上是随层级变化的，
/// 写死类型时"元素明明在、就是查不到"的排查成本极高。这里只关心标识符本身。
func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
}

extension XCTestCase {

    /// 等某个元素满足 `label` 谓词（用于断言"界面上的文案变了"）。
    ///
    /// 比 `XCTAssertTrue(label.contains(...))` + `sleep` 可靠：轮询而不是猜时长，
    /// 也不依赖动画是否播完。
    func waitForLabel(
        of element: XCUIElement,
        contains fragment: String,
        timeout: TimeInterval = 10,
        message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail(
                "等不到 label 含「\(fragment)」，当前 label：\(element.label)。\(message())",
                file: file,
                line: line
            )
        }
    }

    /// 等某个元素消失（用于断言"这条记录真的没了"）。
    ///
    /// `XCTAssertFalse(element.exists)` 紧接着上一句会撞上列表还没重绘的瞬间，
    /// 是这类用例最典型的偶发红。
    func waitForDisappearance(
        of element: XCUIElement,
        timeout: TimeInterval = 10,
        message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTFail("元素始终没消失。\(message())", file: file, line: line)
        }
    }
}
