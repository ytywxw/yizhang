//
//  EntryTemplate.swift
//  一账 / Core / Models
//
//  职责：常用记账模板（V1.1 F-ACC-14 / PRD 5.2）——记账页顶部的一排 chips。
//
//  这是一张**纯输入辅助表**，与账目零引用：
//  账目里不存 `templateID`（PRD 5.3-5），所以删模板不动任何已记账目，
//  改模板也不影响历史。这条边界让模板可以随便删、随便改。
//
//  CloudKit 形状的硬约束（同 `LedgerEntry`）：
//  1. 每个标量都有字面量默认值（`Date` 用 `Date(timeIntervalSince1970: 0)`，
//     绝不用 `.now`——迁移默认值不能依赖"运行那一刻"）；
//  2. 关系全部可选（`Category?` / `Account?`），反向关系在父端（`Category.templates` /
//     `Account.templates`）显式声明 `inverse:`，两侧 deleteRule 都是 `.nullify`；
//  3. 零 `.unique` / `.deny` / `.cascade`；零 `#Index`（iOS 17 不支持）；
//  4. 金额用 `hasAmount: Bool` + `amount: Int64` 表达"可留空"，**不用 `Int64?`**
//     ——可选标量在 CloudKit 与 `#Predicate` 上都是麻烦。
//
//  为什么模板不存日期 / 来源 / 转账：
//  模板解决的是"每天午饭都是餐饮 25 元微信"这类固定组合，日期恒为今天（PRD 5.1），
//  来源只对手动记账有意义，转账模板会让"模板 = 一次复制"的语义复杂到不可解释。
//

import Foundation
import SwiftData

/// 记账模板（最多 20 条，上限由 `TemplateService.limit` 保证）。
@Model
final class EntryTemplate {

    // MARK: - 标量字段（全部带字面量默认值）

    /// 主键。
    var id: UUID = UUID()

    /// 模板名（≤ 20 字，非空；校验在 `TemplateService`，不用 DB 约束）。
    var name: String = ""

    /// `EntryType` 的 raw 值：只允许 expense / income（不支持 transfer）。
    var typeRaw: String = EntryType.expense.raw

    /// 预设金额（分）。`hasAmount == false` 时此值不被使用。
    var amount: Int64 = 0

    /// 是否预设金额。`false` = 只固定分类与账户，金额留给用户当天输入（PRD 5.3-2）。
    var hasAmount: Bool = false

    /// 备注（≤ 100 字，可空）。
    var note: String = ""

    /// 手动排序序号（chips 从左到右）。
    var sortOrder: Int = 0

    /// 创建时间（审计字段）。
    var createdAt: Date = Date(timeIntervalSince1970: 0)

    /// 最后修改时间（审计字段）。
    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: - 关系（全可选；反向关系声明在 Category / Account 侧）

    /// 预设分类。分类被删除后为 nil（`.nullify`），模板仍可用，只是少填一个字段。
    var category: Category? = nil

    /// 预设账户。账户归档后仍保留关系，由 UI 决定是否填入（PRD 5.3-4）。
    var account: Account? = nil

    // MARK: - 初始化

    /// 空初始化。`TemplateService` 是唯一的构造者（保证 20 条上限与字段校验只有一份实现）。
    init() {}

    // MARK: - 便捷计算属性（不参与持久化）

    /// 模板的账目类型。
    var type: EntryType {
        get { EntryType(raw: typeRaw) ?? .expense }
        set { typeRaw = newValue.raw }
    }

    /// 金额值类型（`hasAmount == false` 时仍返回 `.zero`，调用方自行判断是否使用）。
    var amountMoney: Money {
        get { Money(cents: amount) }
        set { amount = newValue.cents }
    }

    /// 名称兜底：空名不显示成一片空白。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名模板" : trimmed
    }

    /// 是否可用于填充（账户已归档 / 分类已隐藏时仍可存在，只是 UI 逐字段降级）。
    var isUsable: Bool { !displayName.isEmpty }
}
