//
//  ExportServiceTests.swift
//  一账Tests / Services
//
//  导出是"数据离开 App"的唯一通道，错一个字都不是"显示不好看"而是"数据错"：
//  ① 没有 BOM → Excel 把中文读成乱码（用户以为文件坏了）；
//  ② 只用了 \n → 部分 Excel 把整个文件读成一行；
//  ③ 备注里的逗号/引号没转义 → 整张表错列，用户看到的金额是别人的；
//  ④ 金额单位混了元/分 → 差 100 倍，这个错误最难被发现。
//
//  所以这里全都是**字节级**断言，不看"大概对不对"。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class ExportServiceTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    // MARK: - ① BOM（字节级）

    func testCSVStartsWithUTF8BOMBytes() {
        let text = ExportService.csv(rows: [makeRow()])
        let bytes = Array(text.utf8)

        XCTAssertEqual(
            Array(bytes.prefix(3)), [0xEF, 0xBB, 0xBF],
            "缺 BOM 时 Excel 会把中文读成乱码，这是导出最常见的失败方式"
        )
        XCTAssertEqual(Array(text.prefix(1)), ["\u{FEFF}"])
    }

    func testExportedFileStartsWithBOMOnDisk() throws {
        let environment = try makeEnvironment()
        let service = ExportService(context: ModelContext(environment.container), today: today)
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try service.export(format: .csv, to: directory)
        let data = try Data(contentsOf: result.url)

        XCTAssertEqual(
            Array(data.prefix(3)), [0xEF, 0xBB, 0xBF],
            "磁盘上的字节也必须带 BOM（内存里对了不代表写出去对了）"
        )
        XCTAssertEqual(result.byteCount, data.count, "byteCount 必须是文件字节数")
        XCTAssertEqual(result.rowCount, 0, "新建库没有账目")
        XCTAssertEqual(result.url.lastPathComponent, "一账-账目-20261121.csv")
    }

    // MARK: - ② CRLF

    func testCSVUsesCRLFOnlyWithNoBareLineFeed() {
        let text = ExportService.csv(rows: [makeRow(), makeRow(note: "第二条")])

        let stripped = text.replacingOccurrences(of: "\r\n", with: "")
        XCTAssertFalse(stripped.contains("\n"), "记录分隔符必须是 CRLF，不能有裸 LF")
        XCTAssertFalse(stripped.contains("\r"), "不能有裸 CR")

        XCTAssertTrue(text.hasSuffix("\r\n"), "最后一行也要有行尾")
        XCTAssertEqual(recordCount(of: text), 3, "表头 + 2 行数据")
    }

    // MARK: - ③ 转义：逗号 / 引号 / 换行 三种必现情况

    func testCSVEscapesCommaInNote() {
        let text = ExportService.csv(rows: [makeRow(note: "买菜,超市")])

        XCTAssertTrue(text.contains("\"买菜,超市\""), "含逗号的字段必须整段加引号")
        XCTAssertEqual(
            fieldCount(ofRowContaining: "买菜", in: text), 10,
            "未转义时这一行会被切成 11 列，转义后仍是 10 列"
        )
    }

    func testCSVEscapesDoubleQuotesInNote() {
        let text = ExportService.csv(rows: [makeRow(note: "他说\"贵\"")])

        XCTAssertTrue(
            text.contains("\"他说\"\"贵\"\"\""),
            "内部双引号必须写成两个，并且整段加引号"
        )
        XCTAssertEqual(fieldCount(ofRowContaining: "他说", in: text), 10)
    }

    func testCSVEscapesNewlineInNote() {
        let text = ExportService.csv(rows: [makeRow(note: "第一行\n第二行")])

        XCTAssertTrue(text.contains("\"第一行\n第二行\""), "含换行的字段必须整段加引号")
        XCTAssertEqual(recordCount(of: text), 2, "引号内的换行是字段内容，不能当成记录分隔符")
    }

    func testPlainFieldIsNotQuoted() {
        XCTAssertEqual(ExportService.escape("午饭"), "午饭")
        XCTAssertEqual(ExportService.escape(""), "")
    }

    // MARK: - 表头（契约）

    func testCSVHeaderMatchesContract() {
        let text = ExportService.csv(rows: [])

        XCTAssertTrue(
            text.contains("日期,类型,金额,分类,账户,收款账户,备注,来源,已删除,创建时间"),
            "表头顺序是契约，改了会让用户已有的脚本失效"
        )
    }

    func testCSVHeaderDropsDeletedColumnWhenNotRequested() {
        let without = ExportService.csv(rows: [], includesDeletedColumn: false)

        XCTAssertTrue(without.contains("日期,类型,金额,分类,账户,收款账户,备注,来源,创建时间"))
        XCTAssertFalse(without.contains("已删除"))
    }

    // MARK: - ④ 金额口径：CSV 元 / JSON 分

    func testCSVAmountIsYuanWithTwoDecimals() {
        let text = ExportService.csv(rows: [makeRow(amountCents: 2_850)])

        XCTAssertTrue(text.contains(",28.50,"), "2850 分要导出成 28.50 元")
        XCTAssertFalse(text.contains("2850"), "CSV 里不能出现分")
    }

    func testJSONAmountIsIntegerCents() throws {
        let text = ExportService.json(rows: [makeRow(amountCents: 2_850)])
        let entry = try firstJSONEntry(in: text)

        XCTAssertEqual(entry["amountCents"] as? Int64, 2_850, "JSON 金额是整数分，不是元")
        XCTAssertEqual(entry["occurredDay"] as? String, "2026-11-20")
        XCTAssertEqual(entry["type"] as? String, "expense")
        XCTAssertEqual(entry["source"] as? String, "manual")
        XCTAssertEqual(entry["deleted"] as? Bool, false)
    }

    func testJSONEnvelopeShape() throws {
        let text = ExportService.json(
            rows: [makeRow()],
            exportedAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["rowCount"] as? Int, 1)

        let exportedAt = try XCTUnwrap(payload["exportedAt"] as? String)
        XCTAssertNotNil(
            ISO8601DateFormatter().date(from: exportedAt),
            "exportedAt 必须是 ISO 8601，机器要能直接解析"
        )

        XCTAssertEqual((payload["entries"] as? [[String: Any]])?.count, 1, "键名是 entries")
    }

    // MARK: - 软删

    func testSoftDeletedEntryIsExportedAndMarkedDeleted() async throws {
        let environment = try makeEnvironment()
        let writer = environment.writer

        var draft = EntryDraft(amount: 1_500, occurredDay: 20261120)
        draft.accountID = try XCTUnwrap(writer.fetch(QueryDescriptors.accounts()).first?.id)
        draft.categoryID = try XCTUnwrap(
            writer.fetch(QueryDescriptors.categories(of: .expense)).first?.id
        )
        draft.note = "买了瓶水"
        let outcome = try environment.ledger.create(draft)
        let entryID = try XCTUnwrap(outcome.entryID)
        _ = await environment.ledger.delete(id: entryID)

        let service = ExportService(context: ModelContext(environment.container), today: today)
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try service.export(format: .csv, to: directory)
        let text = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertEqual(result.rowCount, 1, "软删的账也是用户的数据，导出时要带上")
        XCTAssertTrue(text.contains(",true,"), "`已删除` 列取值是 true")
        XCTAssertTrue(text.contains("买了瓶水"))

        let json = Self.jsonText(from: directory, service: service)
        XCTAssertEqual(try firstJSONEntry(in: json)["deleted"] as? Bool, true, "JSON 的 deleted 是 true")
    }

    // MARK: - 排序

    func testRowsAreSortedByOccurredDayAscending() throws {
        let environment = try makeEnvironment()
        let writer = environment.writer
        let accountID = try XCTUnwrap(writer.fetch(QueryDescriptors.accounts()).first?.id)
        let categoryID = try XCTUnwrap(
            writer.fetch(QueryDescriptors.categories(of: .expense)).first?.id
        )

        // 故意乱序写入（1115 / 1105 / 1120），导出必须是按日期升序。
        // 全部取过去的日子：`LedgerService` 会拒掉未来日期（"futureDate"）。
        for day in [20261115, 20261105, 20261120] as [Int32] {
            var draft = EntryDraft(amount: Int64(day % 1_000), occurredDay: day)
            draft.accountID = accountID
            draft.categoryID = categoryID
            _ = try environment.ledger.create(draft)
        }

        let entries = try writer.fetch(QueryDescriptors.allEntries()).reversed()
        let rows = ExportService.rows(from: Array(entries), categoryNames: [:], accountNames: [:])

        XCTAssertEqual(rows.map(\.occurredDay), [20261105, 20261115, 20261120])
        XCTAssertTrue(rows.allSatisfy { !$0.isDeleted })
    }

    // MARK: - 文件名

    func testFileNameUsesChinesePrefixAndToday() {
        XCTAssertEqual(ExportService.fileName(format: .csv, today: today), "一账-账目-20261121.csv")
        XCTAssertEqual(ExportService.fileName(format: .json, today: today), "一账-账目-20261121.json")
    }

    // MARK: - 空库

    func testEmptyLedgerStillProducesHeaderOnlyFile() throws {
        let environment = try makeEnvironment()
        let service = ExportService(context: ModelContext(environment.container), today: today)
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try service.export(format: .csv, to: directory)
        let text = try String(contentsOf: result.url, encoding: .utf8)

        XCTAssertEqual(result.rowCount, 0)
        XCTAssertEqual(recordCount(of: text), 1, "只有表头一行，不能是空文件")
    }

    // MARK: - 性能（预算 300ms）

    func testTenThousandRowsExportUnder300Milliseconds() {
        let rows = Self.makeStressRows(count: 10_000)

        let started = CFAbsoluteTimeGetCurrent()
        let text = ExportService.csv(rows: rows)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        XCTAssertGreaterThan(text.count, 700_000, "1 万行应该是百万字符量级")
        XCTAssertLessThan(
            elapsed, 300,
            "预算 300ms，实测 \(String(format: "%.1f", elapsed))ms"
        )
        print("[PERF] export 10000 rows: \(String(format: "%.1f", elapsed))ms, \(text.count) chars")
    }

    // MARK: - 夹具

    private func makeEnvironment() throws -> AppEnvironment {
        try AppEnvironment(container: ModelContainerFactory.make(inMemory: true))
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yizhang-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 从同一个服务里再导一份 JSON（软删测试要两种格式都看）。
    private static func jsonText(from directory: URL, service: ExportService) -> String {
        guard let result = try? service.export(format: .json, to: directory),
              let text = try? String(contentsOf: result.url, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func firstJSONEntry(in text: String) throws -> [String: Any] {
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        return try XCTUnwrap(entries.first)
    }

    /// 压测行：刻意带上逗号与引号，让"转义"也在被计时的路径里。
    private static func makeStressRows(count: Int) -> [ExportRow] {
        var rows: [ExportRow] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            rows.append(
                ExportRow(
                    occurredDay: 20261101 + Int32(index % 28),
                    typeRaw: index % 7 == 0 ? EntryType.income.raw : EntryType.expense.raw,
                    amountCents: Int64(100 + index % 9_000),
                    categoryName: "分类\(index % 19)",
                    accountName: "账户\(index % 5)",
                    note: "第 \(index) 条，备注里有逗号也有\"引号\"",
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                )
            )
        }
        return rows
    }

    private func makeRow(note: String = "午饭", amountCents: Int64 = 2_850) -> ExportRow {
        ExportRow(
            occurredDay: 20261120,
            typeRaw: EntryType.expense.raw,
            amountCents: amountCents,
            categoryName: "餐饮",
            accountName: "现金",
            note: note,
            sourceRaw: EntrySource.manual.raw,
            createdAt: Date(timeIntervalSince1970: 1_795_000_000)
        )
    }

    /// 记录数（按 CRLF 计，引号内的换行不算）。
    private func recordCount(of text: String) -> Int {
        text.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count
    }

    /// 找到含 `needle` 的那条记录，按 CSV 规则数它的字段数（引号内的逗号不算分隔符）。
    private func fieldCount(ofRowContaining needle: String, in text: String) -> Int {
        guard let line = text.components(separatedBy: "\r\n").first(where: { $0.contains(needle) }) else {
            return -1
        }
        var count = 1
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                count += 1
            }
        }
        return count
    }
}
