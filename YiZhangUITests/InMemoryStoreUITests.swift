//
//  InMemoryStoreUITests.swift
//  YiZhangUITests
//
//  职责：**spike 专用**——证明 `-YIZHANG_UITEST 1` 真的把 store 切到了内存库。
//
//  判据不能是"测试没报错"：那种"证据"在开关完全没接线时也会成立。
//  唯一算数的正面证明是跨启动不残留 —— 同一条用例内连续启动两次，
//  第二次**不注入**种子，如果还能看到第一遍造的模板，说明数据落盘了，开关没生效。
//
//  为什么用模板而不是分类做判据：`SeedData.seedIfNeeded` 每次冷启动都会写
//  19 个分类 + 5 个账户（那是幂等种子，不是测试数据）。拿"有没有分类"当判据，
//  内存库和磁盘库都会显示"有数据"，反而看不出差别。
//
//  反向验证：本用例带一个自检开关 —— 测试进程设置环境变量 `YIZHANG_FORCE_DISK=1`
//  时不传 `-YIZHANG_UITEST 1`（退回磁盘库），此时第二步**必须变红**。
//  这是证明"判据不是恒绿"的唯一办法：
//      TEST_RUNNER_YIZHANG_FORCE_DISK=1 xcodebuild test ... \
//          -only-testing:YiZhangUITests/InMemoryStoreUITests
//  注意必须带 `TEST_RUNNER_` 前缀：UI 测试跑在模拟器里的独立 runner 进程上，
//  shell 里裸设的环境变量**传不进去**，会让"反向验证"静默变成"再跑一遍正向"。
//  若它照样通过，说明这个用例什么都没证明，别信第一步的绿。
//  2026-11-25 实测：正向（带开关）绿、`TEST_RUNNER_YIZHANG_FORCE_DISK=1` 红
//  （红线落在第二步那条 `XCTAssertFalse` 上），判据有效。
//

import XCTest

final class InMemoryStoreUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// 第一遍注入模板 → 断言 chip 出现；第二遍不注入 → 断言 chip 不出现。
    func testInMemoryStore_DoesNotPersistAcrossLaunches() {
        let app = XCUIApplication()

        // 第一遍：带模板种子
        app.launchArguments = launchArguments(injectTemplates: true)
        app.launch()
        waitForEntrySheet(app)

        let chip = app.buttons["entry.template.午饭"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: 15),
            "第一遍：模板 chip 没出现。要么种子没生效，要么 chips 行没渲染。\n\(app.debugDescription)"
        )

        app.terminate()

        // 第二遍：不带模板种子，其余启动参数完全一致
        app.launchArguments = launchArguments(injectTemplates: false)
        app.launch()
        waitForEntrySheet(app)

        XCTAssertFalse(
            chip.waitForExistence(timeout: 3),
            "第二遍仍然看到了第一遍造的模板 → store 没切到内存库，数据落到磁盘了。"
        )
    }

    // MARK: - 启动

    private func launchArguments(injectTemplates: Bool) -> [String] {
        var args = [
            "-YIZHANG_INITIAL_TAB", "ledger",
            // 记账面板是 sheet，合成不了点击，只能靠钩子直接打开
            "-YIZHANG_DEMO_OPEN", "entry"
        ]
        // 自检开关（见文件头）：置空时退回磁盘库，用来验证本用例不是恒绿。
        if ProcessInfo.processInfo.environment["YIZHANG_FORCE_DISK"] == nil {
            args += ["-YIZHANG_UITEST", "1"]
        }
        if injectTemplates {
            args += ["-YIZHANG_DEMO_TEMPLATES", "1"]
        }
        return args
    }

    /// 等记账面板真的打开。
    ///
    /// 注意**不能**等 `entry.template.create`：没有模板时 `TemplateChipsRow` 整行不渲染，
    /// 第二遍（不注入种子）会永远等不到它，用例会挂在一个和被测结论无关的地方。
    private func waitForEntrySheet(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["entry.save"].waitForExistence(timeout: 20),
            "记账面板没打开。\n\(app.debugDescription)"
        )
    }
}
