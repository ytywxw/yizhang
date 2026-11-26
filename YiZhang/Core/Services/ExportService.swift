//
//  ExportService.swift
//  一账 / Core / Services
//
//  职责：把账目导出成 CSV / JSON（T22）。
//
//  ## 为什么 CSV 的细节必须写死在这里，而不是"随手拼字符串"
//
//  ① **UTF-8 BOM**：没有 BOM，Excel（尤其 Windows 版）会把中文当成 GBK 读，
//     用户看到的是一屏乱码——这是导出功能最常见、也最丢人的失败方式。
//  ② **CRLF 换行**：RFC 4180 规定记录分隔符是 CRLF；只用 \n 在部分 Excel 版本里
//     会把整个文件读成一行。
//  ③ **转义**：字段里出现逗号 / 双引号 / 换行时，整段必须用双引号包起来，
//     内部的双引号写成两个（`""`）。备注是自由文本，这三种情况**必然**出现，
//     漏一条就会让整张表错列——而错列之后用户看到的金额全是别人的。
//  ④ **金额单位**：CSV 给**元**（两位小数，人看），JSON 给 **`amountCents` 整数分**
//     （机读，且避免浮点误差。A1 铁律：钱只有 Int64 分）。
//  ⑤ **含软删记录**：导出是"把数据拿走"的动作。用户自己删掉的账也是他的数据，
//     默认一并导出、用 `已删除` 列标出来，而不是静默吞掉让他对不上账。
//
//  ## 分层：纯函数拼字符串，`@MainActor` 只负责取数和落盘
//
//  `csv` / `json` / `escape` 都是 `nonisolated static func`，输入是 `[ExportRow]`
//  （纯值类型），输出 `String`——不碰 SwiftData、不碰文件系统，
//  于是转义规则可以在**零数据库**的情况下被字节级单测。
//  `@MainActor` 的 `export(format:to:)` 只做三件事：取全量账目 → 拼字符串 → 写临时文件。
//
//  为什么输入用 `ExportRow` 而不是 `LedgerLite`：`LedgerLite` 只有 8 个标量，
//  没有 `note` / `createdAt` / `toAccountID`，用它做输入等于把「备注」「创建时间」
//  「收款账户」三列静默丢掉。`ExportRow` 与 `LedgerLite` 是同一层意思的 DTO
//  （纯值类型、与 `@Model` 解耦、测试不需要容器），只是字段按导出的需要补齐了。
//
//  ## 为什么不用 `FileDocument`
//
//  `FileDocument` 会把整个文件读进内存再交给系统，1 万行 CSV 约 1–3MB，
//  峰值翻倍不说，`fileWrapper` 还是同步调用（会卡主线程）。
//  这里的做法是：拼字符串 → 写临时文件 → 把 URL 交给 `ShareLink(URL)`。
//

import Foundation
import SwiftData

// MARK: - 格式

/// 导出格式。
enum ExportFormat: String, CaseIterable, Hashable, Sendable {
    case csv
    case json

    var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .json: return "JSON"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        }
    }

    /// 副标题（告诉用户这个格式拿去干什么）。
    var hint: String {
        switch self {
        case .csv: return "表格软件可直接打开，金额单位是元"
        case .json: return "完整字段 + 整数分，适合自己再处理"
        }
    }
}

// MARK: - 结果

/// 一次导出的结果。
///
/// `byteCount` 是**文件字节数**（不是字符数）：CSV 里中文一个字符 3 字节，
/// 用字符数去判断"文件多大"会差三倍；字节数才是用户分享出去的真实体积。
struct ExportResult: Hashable, Sendable {

    /// 临时目录里的文件 URL（可直接交给 `ShareLink`）。
    let url: URL
    /// 导出的账目条数（**含软删**，因为导出的就是全量）。
    let rowCount: Int
    /// 文件的字节数。
    let byteCount: Int
}

// MARK: - 行

/// 一行导出数据：纯值类型，与持久化模型解耦，便于在不建库的情况下构造与断言。
struct ExportRow: Hashable, Sendable {

    /// `yyyyMMdd`。
    let occurredDay: Int32
    /// `EntryType` 的 raw 值。
    let typeRaw: String
    /// 金额（分）。业务上 > 0；A1 铁律，钱只有 Int64 分。
    let amountCents: Int64
    let categoryName: String
    let accountName: String
    /// 仅转账有值。
    let toAccountName: String
    let note: String
    /// `EntrySource` 的 raw 值。
    let sourceRaw: String
    let createdAt: Date
    /// 是否软删（`deletedAt != nil`）。
    let isDeleted: Bool
    /// 是否「待确认」的订阅账目（V1.1 F-SUB-13）。
    ///
    /// 只从 `LedgerLite.isPending` / `LedgerEntry.isPending` 取，**不在这里重算**
    /// （确认状态的判据只有 `EntryConfirmation` 一处，导出是"搬运"不是"判断"）。
    let isPending: Bool

    init(
        occurredDay: Int32,
        typeRaw: String,
        amountCents: Int64,
        categoryName: String = "",
        accountName: String = "",
        toAccountName: String = "",
        note: String = "",
        sourceRaw: String = EntrySource.manual.raw,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        isDeleted: Bool = false,
        isPending: Bool = false
    ) {
        self.occurredDay = occurredDay
        self.typeRaw = typeRaw
        self.amountCents = amountCents
        self.categoryName = categoryName
        self.accountName = accountName
        self.toAccountName = toAccountName
        self.note = note
        self.sourceRaw = sourceRaw
        self.createdAt = createdAt
        self.isDeleted = isDeleted
        self.isPending = isPending
    }

    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

    var source: EntrySource { EntrySource(raw: sourceRaw) ?? .manual }

    /// 日期列：`2026-11-21`（CSV 里给人看，也给 Excel 认）。
    var dayText: String {
        let date = DateOnly(key: occurredDay)
        return String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    /// 金额列：元，两位小数。
    ///
    /// 走 `Money.yuanString`（纯整数运算）而不是 `String(format: "%.2f", Double(...))`：
    /// 后者把分成浮点再打回来，大额或极端值上会出现 `0.005` 这种尾差，
    /// 而 CSV 是要被脚本二次解析的，差一分就是错账。
    var yuanText: String {
        Money(cents: amountCents).yuanString
    }

    /// 创建时间列：`2026-11-21 09:30:00`。
    var createdAtText: String {
        ExportDateFormatters.timestamp.string(from: createdAt)
    }
}

// MARK: - 日期格式器

/// 导出专用的格式器。
///
/// 故意放在一个没有 actor 标注的 `enum` 里（而不是 `ExportService` 的静态属性）：
/// `ExportService` 是 `@MainActor`，它的静态存储属性会跟着变成 MainActor 隔离，
/// 于是 `nonisolated static func csv` 就碰不到它们了。这里放外面，天然 nonisolated。
private enum ExportDateFormatters {

    /// 导出里的时间列。固定 `en_US_POSIX` + `yyyy-MM-dd HH:mm:ss`：
    /// 不受模拟器/用户的语言与地区设置影响，用户拿到文件的列宽也稳定。
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// JSON 信封里的 `exportedAt`（ISO 8601，机读）。
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - 服务

/// 导出服务。
///
/// - 纯函数部分（`csv` / `json` / `escape` / `fileName` / `rows`）是
///   `nonisolated static`，可在任何线程调用，测试不需要容器；
/// - `export(format:to:)` 是 `@MainActor`，因为它要读 `ModelContext`（非线程安全）。
@MainActor
final class ExportService {

    // MARK: 契约常量

    /// CSV 表头（顺序即契约，改动会让用户已有的脚本失效）。
    ///
    /// `已删除` 放在 `创建时间` 前面：前 8 列是账目本身的信息，
    /// 后 2 列是"元信息"（是否删过、什么时候录的）。
    nonisolated static let csvHeaderColumns = [
        "日期", "类型", "金额", "分类", "账户", "收款账户", "备注", "来源", "已删除", "创建时间"
    ]

    /// 不带 `已删除` 列时的表头（导出页关掉开关时用）。
    nonisolated static let csvHeaderColumnsWithoutDeleted = [
        "日期", "类型", "金额", "分类", "账户", "收款账户", "备注", "来源", "创建时间"
    ]

    /// 带 `确认状态` 列时的表头（V1.1 F-SUB-13）。
    ///
    /// **为什么另起一个常量而不是改 `csvHeaderColumns`**：
    /// `csvHeaderColumns` 是已发布的契约——用户可能已经按 10 列写好了脚本，
    /// 在中间插一列会让所有既有脚本把「备注」读成「确认状态」。
    /// 新列只在**显式要求**时才出现（`includesConfirmationColumn: true`），
    /// 默认路径逐字不变。
    ///
    /// `确认状态` 排在 `已删除` 之前：它是账目本身的业务状态，
    /// 与"来源"同属一档；`已删除` / `创建时间` 才是后置的元信息。
    nonisolated static let csvHeaderColumnsWithConfirmation = [
        "日期", "类型", "金额", "分类", "账户", "收款账户", "备注", "来源",
        "确认状态", "已删除", "创建时间"
    ]

    /// 带 `确认状态` 列、但不带 `已删除` 列的表头。
    nonisolated static let csvHeaderColumnsWithoutDeletedWithConfirmation = [
        "日期", "类型", "金额", "分类", "账户", "收款账户", "备注", "来源",
        "确认状态", "创建时间"
    ]

    /// 按两个开关选表头。
    ///
    /// 表头与下面的数据行必须由**同一组开关**决定，否则整张表会错列——
    /// 错列之后用户看到的金额全是别人的，这是导出功能最致命的一种 bug。
    /// 所以两个开关只在这里各判一次，`csv` 的表头与行都从这里出发。
    ///
    /// - Parameters:
    ///   - includesDeletedColumn: 是否保留 `已删除` 列。
    ///   - includesConfirmationColumn: 是否保留 `确认状态` 列。
    /// - Returns: 与当前开关匹配的表头（四个组合各有一个常量，逐字可断言）。
    nonisolated static func headerColumns(
        includesDeletedColumn: Bool,
        includesConfirmationColumn: Bool
    ) -> [String] {
        switch (includesDeletedColumn, includesConfirmationColumn) {
        case (true, false): return csvHeaderColumns
        case (false, false): return csvHeaderColumnsWithoutDeleted
        case (true, true): return csvHeaderColumnsWithConfirmation
        case (false, true): return csvHeaderColumnsWithoutDeletedWithConfirmation
        }
    }

    /// CSV 记录分隔符（RFC 4180：CRLF，不是 \n）。
    nonisolated static let recordSeparator = "\r\n"

    /// UTF-8 BOM：没有它，Excel 会把中文读成乱码。
    nonisolated static let byteOrderMark = "\u{FEFF}"

    // MARK: 依赖

    /// 只读上下文（取数用；本服务从不写入）。
    private let context: ModelContext

    /// 文件名里的日期（测试注入固定日期，保证断言稳定）。
    private let today: DateOnly

    init(context: ModelContext, today: DateOnly = DateOnly(Date())) {
        self.context = context
        self.today = today
    }

    // MARK: 取数 + 落盘

    /// 导出全量账目（**含软删**，按 `occurredDay` 升序），写到临时文件。
    ///
    /// - Parameters:
    ///   - format: `.csv` 或 `.json`。
    ///   - directory: 目标目录；`nil` 表示 `FileManager.default.temporaryDirectory`。
    /// - Returns: 文件 URL、条数、字节数。
    /// - Throws: 读取数据库失败，或文本无法编码成 UTF-8。
    func export(format: ExportFormat, to directory: URL? = nil) throws -> ExportResult {
        let entries = try context.fetch(QueryDescriptors.allEntries())
        let categories = try context.fetch(QueryDescriptors.categories(of: .expense, includeHidden: true))
            + context.fetch(QueryDescriptors.categories(of: .income, includeHidden: true))
        let accounts = try context.fetch(QueryDescriptors.accounts(includeArchived: true))

        let categoryNames = Dictionary(
            categories.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let accountNames = Dictionary(
            accounts.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )

        // 导出永远拿全量（含软删）；是否可见由用户拿文件后自己判断。
        let rows = Self.rows(
            from: entries,
            categoryNames: categoryNames,
            accountNames: accountNames,
            includesDeleted: true
        )

        let text = Self.text(rows: rows, format: format, includesDeletedColumn: true)
        guard let data = text.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }

        let targetDirectory = directory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let url = targetDirectory.appendingPathComponent(
            Self.fileName(format: format, today: today)
        )
        // `.atomic`：先写临时文件再改名，分享面板拿到的一定是完整文件。
        try data.write(to: url, options: .atomic)

        return ExportResult(url: url, rowCount: rows.count, byteCount: data.count)
    }

    // MARK: CSV（纯函数）

    /// 生成 CSV 文本（**已含 BOM**，记录分隔符是 CRLF）。
    ///
    /// - Parameters:
    ///   - rows: 数据行（调用方已按需过滤软删）。
    ///   - includesDeletedColumn: 是否保留 `已删除` 列（默认保留，符合导出规范）。
    ///   - includesConfirmationColumn: 是否保留 `确认状态` 列。
    ///     **默认 `false`**：默认表头必须逐字等于 `csvHeaderColumns`（已发布契约），
    ///     需要这一列的地方（导出页）显式传 `true`。
    /// - Returns: 可直接写入文件的字符串。
    nonisolated static func csv(
        rows: [ExportRow],
        includesDeletedColumn: Bool = true,
        includesConfirmationColumn: Bool = false
    ) -> String {
        var output = byteOrderMark
        output.reserveCapacity(rows.count * 96 + 128)

        let header = headerColumns(
            includesDeletedColumn: includesDeletedColumn,
            includesConfirmationColumn: includesConfirmationColumn
        )
        output += header.map(escape).joined(separator: ",")
        output += recordSeparator

        for row in rows {
            var fields = [
                row.dayText,
                row.type.displayName,
                row.yuanText,
                row.categoryName,
                row.accountName,
                row.toAccountName,
                row.note,
                row.source.displayName
            ]
            if includesConfirmationColumn {
                // 与 `已删除` 列同理给机读值（`pending` / `confirmed`），
                // 而不是"待确认 / 已确认"：这一列是给脚本过滤用的。
                fields.append(row.isPending ? "pending" : "confirmed")
            }
            if includesDeletedColumn {
                // 用 true / false 而不是"是 / 否"：这一列是给脚本过滤用的。
                fields.append(row.isDeleted ? "true" : "false")
            }
            fields.append(row.createdAtText)
            output += fields.map(escape).joined(separator: ",")
            output += recordSeparator
        }
        return output
    }

    /// 单个字段的 CSV 转义（RFC 4180）。
    ///
    /// 只要字段里出现 `,` `"` `\n` `\r` 中的任意一个，就整段加引号；
    /// 内部引号写成两个。这四种字符都可能出现在用户备注里。
    nonisolated static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")

        guard needsQuoting else { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: JSON（纯函数）

    /// 生成 JSON：`{"version":1,"exportedAt":"…","entries":[…]}`。
    ///
    /// 每条含 `amountCents`（整数分）、`occurredDay`（`2026-11-21`）、
    /// `type` / `source`（raw 值，机读）、`deleted`（Bool）、
    /// `confirmation`（`pending` / `confirmed`，V1.1）。
    ///
    /// `deleted` 与 `confirmation` **恒定存在**（不随导出页的开关变化）：
    /// JSON 是给程序读的，少一个字段就得让消费方按"有没有开关"写两套解析逻辑。
    nonisolated static func json(rows: [ExportRow], exportedAt: Date = Date()) -> String {
        var entries: [[String: Any]] = []
        entries.reserveCapacity(rows.count)

        for row in rows {
            entries.append([
                "occurredDay": row.dayText,
                "type": row.typeRaw,
                "amountCents": row.amountCents,
                "category": row.categoryName,
                "account": row.accountName,
                "toAccount": row.toAccountName,
                "note": row.note,
                "source": row.sourceRaw,
                "confirmation": row.isPending ? "pending" : "confirmed",
                "createdAt": row.createdAtText,
                "deleted": row.isDeleted
            ])
        }

        let payload: [String: Any] = [
            "version": 1,
            "app": "一账",
            "exportedAt": ExportDateFormatters.iso8601.string(from: exportedAt),
            "rowCount": rows.count,
            "entries": entries
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            // 走到这里说明数据里有无法序列化的类型（正常不可能），
            // 返回一个空信封而不是崩掉——导出失败不该让 App 退出。
            return "{\"version\":1,\"rowCount\":0,\"entries\":[]}"
        }
        return text
    }

    // MARK: 组装文本

    /// 按格式生成文本（CSV 已含 BOM）。
    nonisolated static func text(
        rows: [ExportRow],
        format: ExportFormat,
        includesDeletedColumn: Bool = true,
        includesConfirmationColumn: Bool = false,
        exportedAt: Date = Date()
    ) -> String {
        switch format {
        case .csv:
            return csv(
                rows: rows,
                includesDeletedColumn: includesDeletedColumn,
                includesConfirmationColumn: includesConfirmationColumn
            )
        case .json:
            // JSON 不看任何列开关：`confirmation` 恒定存在，理由见 `json(rows:exportedAt:)`
            return json(rows: rows, exportedAt: exportedAt)
        }
    }

    // MARK: 文件名

    /// `一账-账目-20261121.csv`
    nonisolated static func fileName(
        format: ExportFormat,
        today: DateOnly = DateOnly(Date())
    ) -> String {
        String(
            format: "一账-账目-%04d%02d%02d.%@",
            today.year, today.month, today.day, format.fileExtension
        )
    }

    // MARK: 组装行

    /// `LedgerEntry` → `ExportRow`（名称在这里就解析好，拼字符串阶段不再碰数据库关系）。
    ///
    /// 结果按 `occurredDay` 升序；同一天内按 `createdAt` 升序（再按 id 兜底，
    /// 保证同样的数据导出两次字节完全一致——测试与 diff 都要这个性质）。
    ///
    /// - Parameters:
    ///   - entries: 全部账目（**含软删**，是否写进文件由 `includesDeleted` 决定）。
    ///   - categoryNames: 分类 id → 名称。
    ///   - accountNames: 账户 id → 显示名。
    ///   - includesDeleted: `false` 时过滤掉软删记录。
    nonisolated static func rows(
        from entries: [LedgerEntry],
        categoryNames: [UUID: String],
        accountNames: [UUID: String],
        includesDeleted: Bool = true
    ) -> [ExportRow] {
        let filtered = includesDeleted ? entries : entries.filter { $0.deletedAt == nil }

        let sorted = filtered.sorted { lhs, rhs in
            if lhs.occurredDay != rhs.occurredDay { return lhs.occurredDay < rhs.occurredDay }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        return sorted.map { entry in
            ExportRow(
                occurredDay: entry.occurredDay,
                typeRaw: entry.typeRaw,
                amountCents: entry.amount,
                categoryName: entry.category.flatMap { categoryNames[$0.id] } ?? "",
                accountName: entry.account.flatMap { accountNames[$0.id] } ?? "",
                toAccountName: entry.toAccount.flatMap { accountNames[$0.id] } ?? "",
                note: entry.note,
                sourceRaw: entry.sourceRaw,
                createdAt: entry.createdAt,
                isDeleted: entry.deletedAt != nil,
                // 确认状态只从模型上读（唯一判据在 `EntryConfirmation`），不在这里重算
                isPending: entry.isPending
            )
        }
    }

    // MARK: 后台落盘（导出页用）

    /// 在后台线程拼字符串 + 落盘，返回可交给 `ShareLink` 的 URL。
    ///
    /// `Task.detached` 而不是 `Task {}`：后者继承当前 actor（多半是 MainActor），
    /// 等于白写——1 万行拼接期间主线程照样卡住。
    nonisolated static func makeFileInBackground(
        rows: [ExportRow],
        format: ExportFormat,
        includesDeletedColumn: Bool = true,
        includesConfirmationColumn: Bool = false,
        today: DateOnly = DateOnly(Date())
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let text = text(
                rows: rows,
                format: format,
                includesDeletedColumn: includesDeletedColumn,
                includesConfirmationColumn: includesConfirmationColumn
            )
            guard let data = text.data(using: .utf8) else {
                throw ExportError.encodingFailed
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("yizhang-export", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(format: format, today: today))
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }
}

// MARK: - 错误

/// 导出错误。
enum ExportError: LocalizedError, Hashable {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "导出内容无法编码成 UTF-8"
        }
    }
}
