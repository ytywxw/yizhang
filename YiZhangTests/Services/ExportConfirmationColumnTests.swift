//
//  ExportConfirmationColumnTests.swift
//  一账Tests / Services
//
//  职责：钉死导出里的「确认状态」列（V1.1 / T3 §5-⑥⑦）。
//
//  ## 这组用例真正防的是什么
//
//  `csvHeaderColumns` 是**已发布的契约**：用户可能已经按 10 列写好了脚本，
//  在中间插一列会让所有既有脚本把「备注」读成「确认状态」——错列之后
//  用户看到的金额全是别人的，这是导出功能最致命的一类 bug。
//  所以这里的第一条断言是"默认路径逐字不变"，不是"新列能出来"。
//
//  第二条防的是**表头与数据行由不同开关决定**：`csv` 里表头走 `headerColumns(...)`、
//  行内用 `if includesConfirmationColumn` / `if includesDeletedColumn` 两次判断，
//  只要有一处写错，两者的列数就会不一致（11 列表头 + 10 列数据）。
//  因此每条用都同时断言「表头列数 == 数据行列数」。
//
//  第三条防的是"JSON 跟着 CSV 开关走"：JSON 是给程序读的，
//  少一个字段就得让消费方按"有没有开关"写两套解析逻辑，所以它恒定带 `confirmation`。
//

import SwiftData
import XCTest
@testable import YiZhang

@MainActor
final class ExportConfirmationColumnTests: XCTestCase {

    // MARK: - ⑥ 默认表头逐字等于已发布契约

    func testDefaultCSVHeaderIsByteIdenticalToPublishedContract() {
        let text = ExportService.csv(rows: [])
        let header = headerRecord(of: text)

        XCTAssertEqual(
            header,
            ExportService.csvHeaderColumns.joined(separator: ","),
            "默认表头必须逐字等于 `csvHeaderColumns`（已发布契约，任务是加法不是改口径）"
        )
        XCTAssertEqual(header.components(separatedBy: ",").count, 10)
        XCTAssertFalse(header.contains("确认状态"), "默认路径不该出现新列")
    }

    func testDefaultCSVDataRowKeepsTenColumns() {
        let text = ExportService.csv(rows: [makeRow(isPending: true)])

        XCTAssertEqual(
            headerRecord(of: text).components(separatedBy: ",").count,
            dataRecord(of: text).components(separatedBy: ",").count,
            "表头与数据行必须由同一组开关决定，列数不一致就是整张表错列"
        )
        XCTAssertEqual(dataRecord(of: text).components(separatedBy: ",").count, 10)
    }

    // MARK: - ⑥ 开启后的表头与整行

    func testConfirmationColumnIsInsertedBeforeDeletedColumn() {
        let text = ExportService.csv(rows: [makeRow(isPending: true)], includesConfirmationColumn: true)

        let header = headerRecord(of: text)
        XCTAssertEqual(
            header,
            ExportService.csvHeaderColumnsWithConfirmation.joined(separator: ",")
        )
        // 「确认状态」是账目本身的业务状态，与「来源」同档；
        // 「已删除」「创建时间」才是后置元信息 —— 位置错了用户按列号写的脚本就废了。
        XCTAssertEqual(
            header.components(separatedBy: ","),
            [
                "日期", "类型", "金额", "分类", "账户", "收款账户", "备注", "来源",
                "确认状态", "已删除", "创建时间"
            ]
        )

        let fields = dataRecord(of: text).components(separatedBy: ",")
        XCTAssertEqual(fields.count, 11, "行也必须 11 列")
        XCTAssertEqual(fields[7], EntrySource.manual.displayName, "第 8 列仍是来源")
        XCTAssertEqual(fields[8], "pending", "第 9 列是确认状态（机读值）")
        XCTAssertEqual(fields[9], "false", "第 10 列仍是已删除")
    }

    func testConfirmationColumnWritesConfirmedForNonPendingRows() {
        let text = ExportService.csv(rows: [makeRow(isPending: false)], includesConfirmationColumn: true)
        let fields = dataRecord(of: text).components(separatedBy: ",")

        XCTAssertEqual(fields.count, 11)
        XCTAssertEqual(fields[8], "confirmed")
    }

    func testWithoutDeletedColumnButWithConfirmationKeepsColumnCount() {
        let text = ExportService.csv(
            rows: [makeRow(isPending: true)],
            includesDeletedColumn: false,
            includesConfirmationColumn: true
        )

        XCTAssertEqual(
            headerRecord(of: text),
            ExportService.csvHeaderColumnsWithoutDeletedWithConfirmation.joined(separator: ",")
        )
        XCTAssertFalse(headerRecord(of: text).contains("已删除"))

        let fields = dataRecord(of: text).components(separatedBy: ",")
        XCTAssertEqual(fields.count, 10)
        XCTAssertEqual(fields[8], "pending")
    }

    func testHeaderSelectorCoversAllFourSwitchCombinations() {
        // 四个组合各有一个常量，逐字可断言 —— 这是"表头只有一个出口"的机器可验证形式。
        XCTAssertEqual(
            ExportService.headerColumns(includesDeletedColumn: true, includesConfirmationColumn: false),
            ExportService.csvHeaderColumns
        )
        XCTAssertEqual(
            ExportService.headerColumns(includesDeletedColumn: false, includesConfirmationColumn: false),
            ExportService.csvHeaderColumnsWithoutDeleted
        )
        XCTAssertEqual(
            ExportService.headerColumns(includesDeletedColumn: true, includesConfirmationColumn: true),
            ExportService.csvHeaderColumnsWithConfirmation
        )
        XCTAssertEqual(
            ExportService.headerColumns(includesDeletedColumn: false, includesConfirmationColumn: true),
            ExportService.csvHeaderColumnsWithoutDeletedWithConfirmation
        )
    }

    func testTextAndMakeFileInBackgroundDefaultToTenColumns() async throws {
        // 默认值必须是"关"：`export(format:to:)` 与所有既有调用点都走默认路径。
        XCTAssertEqual(
            headerRecord(of: ExportService.text(rows: [], format: .csv)),
            ExportService.csvHeaderColumns.joined(separator: ",")
        )

        let url = try await ExportService.makeFileInBackground(
            rows: [makeRow(isPending: true)],
            format: .csv,
            today: DateOnly(key: 20261121)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            headerRecord(of: written),
            ExportService.csvHeaderColumns.joined(separator: ","),
            "写盘路径（后台线程）也必须守住默认表头"
        )
    }

    // MARK: - ⑦ JSON 无条件带 confirmation

    func testJSONCarriesConfirmationForBothStates() throws {
        let text = ExportService.json(rows: [
            makeRow(isPending: true),
            makeRow(isPending: false)
        ])

        XCTAssertTrue(text.contains("\"confirmation\""), "JSON 的键名是契约，少一个字段就得让消费方写两套解析")

        let entries = try entries(of: text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["confirmation"] as? String, "pending")
        XCTAssertEqual(entries[1]["confirmation"] as? String, "confirmed")
    }

    func testJSONIgnoresCSVColumnSwitches() throws {
        // 走 `text(format: .json)` 时即使把 CSV 的列开关关掉，JSON 仍要带 confirmation：
        // 开关是给"人看的表格"用的，JSON 是给机读的。
        let text = ExportService.text(
            rows: [makeRow(isPending: true)],
            format: .json,
            includesDeletedColumn: false,
            includesConfirmationColumn: false,
            exportedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(text.contains("\"confirmation\""))
        XCTAssertEqual(try entries(of: text)[0]["confirmation"] as? String, "pending")
        XCTAssertNotNil(try entries(of: text)[0]["deleted"], "`deleted` 也恒定存在")
    }

    // MARK: - 端到端：`isPending` 只能从模型读出来

    func testExportRowsDeriveIsPendingFromModel() throws {
        // 这条是本组最重要的一条：上面所有断言都建立在"`ExportRow.isPending` 有人填"之上。
        // 若 `rows(from:)` 漏了这一行，前面全绿而线上导出的确认状态恒为 confirmed。
        let environment = try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
        let writer = environment.writer
        let categoryID = try XCTUnwrap(
            writer.fetch(QueryDescriptors.categories(of: .expense)).first?.id
        )
        let accountID = try XCTUnwrap(writer.fetch(QueryDescriptors.accounts()).first?.id)

        var pending = EntryDraft(typeRaw: EntryType.expense.raw, amount: 2500, occurredDay: 20261120)
        pending.categoryID = categoryID
        pending.accountID = accountID
        pending.sourceRaw = EntrySource.subscription.raw
        pending.sourceRefID = UUID()
        pending.sourceCycleKey = "cycle-\(UUID().uuidString.prefix(8))"
        pending.confirmRaw = EntryConfirmation.pending.raw
        _ = try writer.insert(pending)

        var confirmed = EntryDraft(typeRaw: EntryType.expense.raw, amount: 900, occurredDay: 20261121)
        confirmed.categoryID = categoryID
        confirmed.accountID = accountID
        confirmed.confirmRaw = EntryConfirmation.confirmed.raw
        _ = try writer.insert(confirmed)

        let allEntries = try writer.fetch(QueryDescriptors.allEntries())
        let rows = ExportService.rows(from: allEntries, categoryNames: [:], accountNames: [:])

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter(\.isPending).map(\.amountCents), [2500], "待确认那条必须被标出来")

        // 落到文件上也一致（CSV 第 9 列 / JSON 的 confirmation）
        let csvText = ExportService.csv(rows: rows, includesConfirmationColumn: true)
        let csvLines = records(of: csvText).dropFirst()
        XCTAssertTrue(csvLines.contains { $0.contains(",pending,") }, "CSV 里要出现 pending")
        XCTAssertTrue(csvLines.contains { $0.contains(",confirmed,") }, "CSV 里要出现 confirmed")

        let jsonText = ExportService.json(rows: rows)
        XCTAssertEqual(try entries(of: jsonText).filter { $0["confirmation"] as? String == "pending" }.count, 1)
    }

    // MARK: - 夹具

    private func makeRow(note: String = "午饭", amountCents: Int64 = 2_850, isPending: Bool = false) -> ExportRow {
        ExportRow(
            occurredDay: 20261120,
            typeRaw: EntryType.expense.raw,
            amountCents: amountCents,
            categoryName: "餐饮",
            accountName: "现金",
            note: note,
            sourceRaw: EntrySource.manual.raw,
            createdAt: Date(timeIntervalSince1970: 1_795_000_000),
            isPending: isPending
        )
    }

    /// 记录数（按 CRLF 切，去掉 BOM 与空段）。
    private func records(of text: String) -> [String] {
        text.replacingOccurrences(of: ExportService.byteOrderMark, with: "")
            .components(separatedBy: ExportService.recordSeparator)
            .filter { !$0.isEmpty }
    }

    private func headerRecord(of text: String) -> String {
        records(of: text).first ?? ""
    }

    private func dataRecord(of text: String) -> String {
        records(of: text).dropFirst().first ?? ""
    }

    private func entries(of text: String) throws -> [[String: Any]] {
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(payload["entries"] as? [[String: Any]])
    }
}
