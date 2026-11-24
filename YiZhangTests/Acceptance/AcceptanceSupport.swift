//
//  AcceptanceSupport.swift
//  YiZhangTests / Acceptance
//
//  验收测试的公共装配与工具。原则：
//  ① **只走真实链路**：真实 `ModelContainer`（内存库）+ 真实 `SeedData` + 真实 Service，
//     不 mock、不桩；验收要回答的是"用户按下去会发生什么"，mock 掉的正是答案本身。
//  ② **可重复**：所有"今天"由测试注入固定日（`DateOnly(key:)`），不读系统时钟；
//     不依赖网络；每个用例自建容器，不依赖上一次运行的残留。
//  ③ **可模拟"跨启动"**：同一个容器 + 全新的 `AppEnvironment`（全新 context 与服务实例），
//     等价于用户杀掉 App 再打开——这是订阅补漏、幂等、软删等场景的关键前提。
//

import Foundation
import SwiftData
import XCTest
@testable import YiZhang

// MARK: - 失败信息

/// 验收辅助函数用的错误（让失败原因在报告里可读，而不是一句 generic 报错）。
struct AcceptanceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 一次「App 启动」

/// 一次完整的 App 装配：容器 + 种子 + 全部真实服务。
@MainActor
struct AcceptanceWorld {

    let container: ModelContainer
    let env: AppEnvironment

    /// 启动一次 App。
    ///
    /// - Parameter container: 传入上一次的容器 = 模拟"关掉再打开"（同一份存储，全新 context）。
    static func boot(reusing container: ModelContainer? = nil) throws -> AcceptanceWorld {
        let store = try container ?? ModelContainerFactory.make(inMemory: true)
        let env = try AppEnvironment(container: store)
        return AcceptanceWorld(container: store, env: env)
    }

    // MARK: 读

    /// 全部账目；默认排除软删（列表/统计口径）。
    func entries(includeDeleted: Bool = false) throws -> [LedgerEntry] {
        let all = try env.readContext.fetch(QueryDescriptors.allEntries())
        return includeDeleted ? all : all.filter { $0.deletedAt == nil }
    }

    /// 某月账目（走首页同一条 `QueryDescriptors.monthEntries`）。
    func entries(inMonth monthKey: Int32) throws -> [LedgerEntry] {
        try env.readContext.fetch(QueryDescriptors.monthEntries(monthKey))
    }

    func entry(id: UUID) throws -> LedgerEntry? {
        try env.readContext.fetch(QueryDescriptors.entry(id: id)).first
    }

    /// 统计用的轻量视图（与 T19 取数路径一致）。
    func lites(includeDeleted: Bool = true) throws -> [LedgerLite] {
        try entries(includeDeleted: includeDeleted).map { entry in
            LedgerLite(
                id: entry.id,
                amount: entry.amount,
                typeRaw: entry.typeRaw,
                occurredDay: entry.occurredDay,
                categoryID: entry.category?.id,
                accountID: entry.account?.id,
                sourceRaw: entry.sourceRaw,
                deletedAt: entry.deletedAt
            )
        }
    }

    func expenseCategories() throws -> [YiZhang.Category] {
        try env.readContext.fetch(QueryDescriptors.categories(of: .expense))
    }

    func accounts() throws -> [Account] {
        try env.readContext.fetch(QueryDescriptors.accounts())
    }

    func firstAccount() throws -> Account {
        guard let account = try accounts().first else {
            throw AcceptanceFailure("种子数据里没有账户，验收前提不成立")
        }
        return account
    }

    func secondAccount() throws -> Account {
        let all = try accounts()
        guard all.count > 1 else {
            throw AcceptanceFailure("种子数据里只有一个账户，无法构造转账")
        }
        return all[1]
    }

    func defaultExpenseCategory() throws -> YiZhang.Category {
        guard let category = try expenseCategories().first else {
            throw AcceptanceFailure("种子数据里没有支出分类")
        }
        return category
    }

    // MARK: 写（全部经 Service）

    /// 记一笔手动账。
    @discardableResult
    func manual(
        amount: Int64,
        day: Int32,
        note: String = "",
        categoryID: UUID? = nil,
        accountID: UUID? = nil
    ) throws -> UUID {
        var draft = EntryDraft(amount: amount, occurredDay: day)
        draft.note = note
        if let categoryID {
            draft.categoryID = categoryID
        } else {
            draft.categoryID = try defaultExpenseCategory().id
        }
        if let accountID {
            draft.accountID = accountID
        } else {
            draft.accountID = try firstAccount().id
        }
        let outcome = try env.ledger.create(draft)
        guard let id = outcome.entryID else {
            throw AcceptanceFailure("手动记账被幂等键挡掉了（不应发生：手动账没有幂等键）")
        }
        return id
    }

    /// 记一笔转账（用于验证"转账不计入收支"）。
    @discardableResult
    func transfer(amount: Int64, day: Int32, note: String = "还款") throws -> UUID {
        var draft = EntryDraft(typeRaw: EntryType.transfer.raw, amount: amount, occurredDay: day)
        draft.note = note
        draft.accountID = try firstAccount().id
        draft.toAccountID = try secondAccount().id
        let outcome = try env.ledger.create(draft)
        guard let id = outcome.entryID else {
            throw AcceptanceFailure("转账被幂等键挡掉了（不应发生）")
        }
        return id
    }

    // MARK: 断言工具

    /// 某来源的账目（含软删，便于验证"软删仍占幂等键"）。
    func entries(ofSource source: EntrySource, includeDeleted: Bool = false) throws -> [LedgerEntry] {
        try entries(includeDeleted: true).filter {
            $0.source == source && (includeDeleted || $0.deletedAt == nil)
        }
    }
}

// MARK: - 固定"今天"

/// 验收统一使用的时间基准：2026-11-21。
///
/// 选它而不是 `Date()` 的原因：补漏/试用/暂停恢复这类场景全是"日期算术"，
/// 依赖真实当前时间会让断言在跨月、跨年、闰年时随机失败。
enum AcceptanceToday {
    static let key: Int32 = 20261121
    static var value: DateOnly { DateOnly(key: key) }
}

// MARK: - 最小 RFC 4180 CSV 解析器

/// 标准 CSV 解析器（RFC 4180）：双引号包裹、内部引号翻倍、引号内允许逗号与换行、
/// 记录分隔符 CRLF。
///
/// 存在的意义：**不能自己写的导出用自己写的解析器去验**——那样两边一起错也发现不了。
/// 这里严格按 RFC 4180 实现，与 `ExportService` 的实现无共享代码。
enum CSVTestParser {

    /// 解析成二维表（含表头行）。
    ///
    /// 实现注记：Swift 里 `"\r\n"` 是**一个** `Character`（CRLF 是一个字素簇），
    /// 所以必须显式把 `"\r\n"` 当成记录分隔符来匹配，否则整个文件会被读成一行——
    /// 这正是"自己写解析器验自己写导出"最容易踩的坑。
    static func records(from text: String) -> [[String]] {
        var characters = Array(text)
        if characters.first == "\u{FEFF}" { characters.removeFirst() }

        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
                index += 1

            case ",":
                fields.append(field)
                field = ""
                index += 1

            case "\r\n", "\n", "\r":
                fields.append(field)
                field = ""
                records.append(fields)
                fields = []
                index += 1

            default:
                field.append(character)
                index += 1
            }
        }

        if !field.isEmpty || !fields.isEmpty {
            fields.append(field)
            records.append(fields)
        }
        return records
    }
}
