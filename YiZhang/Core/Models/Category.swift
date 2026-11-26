//
//  Category.swift
//  一账 / Core / Models
//
//  职责：分类模型（PRD 3.2.3 / 架构 §3.2）。纯数据 + 便捷计算属性。
//
//  R-CAT：分类与账目类型强绑定（支出分类不能用于收入账目）；预置分类可隐藏不可删除；
//  删除自定义分类时必须迁移账目，不允许产生无分类账目（迁移逻辑在 Service 层，T21）。
//
//  CloudKit 形状约束同 `LedgerEntry`。
//

import Foundation
import SwiftData

/// 账目分类（支出 14 个 + 收入 5 个预置）。
@Model
final class Category {

    // MARK: - 标量字段

    var id: UUID = UUID()

    /// 分类名称，同 type 下不可重名（业务层校验，不用 DB 唯一约束）。
    var name: String = ""

    /// `EntryType` 的 raw 值：expense / income。分类与账目类型强绑（R-CAT）。
    var typeRaw: String = EntryType.expense.raw

    /// SF Symbols 名称，从内置 40 个精选图标中选。
    var iconName: String = "circle"

    /// 品牌色板中的颜色，`#RRGGBB`。
    var colorHex: String = "#8E8E93"

    /// 预置分类不可删除，只能隐藏（R-CAT-1）。
    var isPreset: Bool = false

    /// 隐藏后不出现在选择器中，历史账目仍可正常显示。
    var isHidden: Bool = false

    var sortOrder: Int = 0

    var createdAt: Date = Date(timeIntervalSince1970: 0)

    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: - 关系

    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.category)
    var entries: [LedgerEntry]? = []

    @Relationship(deleteRule: .nullify, inverse: \Todo.category)
    var todos: [Todo]? = []

    @Relationship(deleteRule: .nullify, inverse: \Subscription.category)
    var subscriptions: [Subscription]? = []

    /// 以本分类为预设分类的记账模板（V1.1 F-ACC-14）。
    ///
    /// 反向关系必须显式写 `inverse:`（CloudKit 强制要求），且与本模型侧一样是 `.nullify`：
    /// 分类被删除时只把模板的分类置空，**绝不**连带删模板——模板是输入辅助，
    /// 丢一个字段可以接受，丢一整条模板不行。两侧 deleteRule 不一致会导致启动即崩。
    @Relationship(deleteRule: .nullify, inverse: \EntryTemplate.category)
    var templates: [EntryTemplate]? = []

    // MARK: - 初始化

    init() {}

    // MARK: - 便捷计算属性（不参与持久化）

    /// 分类所属的账目类型。
    var type: EntryType {
        get { EntryType(raw: typeRaw) ?? .expense }
        set { typeRaw = newValue.raw }
    }

    var isExpenseCategory: Bool { type == .expense }

    var isIncomeCategory: Bool { type == .income }

    /// 预置分类不可删（只能隐藏）。
    var canDelete: Bool { !isPreset }

    /// 是否出现在选择器中。
    var isSelectable: Bool { !isHidden }

    /// 名称兜底。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }

    /// 图标兜底（空字符串会让 SF Symbols 渲染成空白）。
    var displayIconName: String {
        let trimmed = iconName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "circle" : trimmed
    }

    /// 该分类下是否有任何账目（删除时强制迁移的判据，R-CAT-2）。
    var hasAnyEntries: Bool { entries?.isEmpty == false }
}
