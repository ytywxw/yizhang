//
//  Account.swift
//  一账 / Core / Models
//
//  职责：账户模型（PRD 3.2.2 / 架构 §3.2）。纯数据 + 便捷计算属性。
//
//  R-ACC-1：账户余额 = 期初 - Σ支出 + Σ收入 - Σ转出 + Σ转入，**只读计算**，不允许手改。
//  余额的计算实现放在 `Domain/AccountBalanceCalculator`（T06），本文件只暴露 `initialBalance`。
//
//  CloudKit 形状约束同 `LedgerEntry`：标量有默认值、关系全可选、to-many 显式 inverse、
//  无 `.unique` / `.deny` / `.cascade`、无 `#Index`。
//

import Foundation
import SwiftData

/// 账户（现金 / 储蓄卡 / 信用卡 / 支付宝 / 微信 / 其他）。
@Model
final class Account {

    // MARK: - 标量字段

    var id: UUID = UUID()

    /// 账户名称，如「招行储蓄卡」。
    var name: String = ""

    /// `AccountKind` 的 raw 值：cash / debit / credit / alipay / wechat / other。
    var kindRaw: String = AccountKind.cash.raw

    /// 期初余额（分），仅用于展示计算（R-ACC-1），不参与收支统计。
    var initialBalance: Int64 = 0

    /// 归档后不出现在记账选择器中，但历史账目保留。
    var isArchived: Bool = false

    /// 手动排序。
    var sortOrder: Int = 0

    var createdAt: Date = Date(timeIntervalSince1970: 0)

    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: - 关系（反向关系在此显式声明，被 CloudKit 强制要求）

    /// 以本账户为付款账户的账目。
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.account)
    var entries: [LedgerEntry]? = []

    /// 转入本账户的账目（仅转账）。
    @Relationship(deleteRule: .nullify, inverse: \LedgerEntry.toAccount)
    var incomingTransfers: [LedgerEntry]? = []

    /// 扣费账户为本账户的订阅。
    @Relationship(deleteRule: .nullify, inverse: \Subscription.account)
    var subscriptions: [Subscription]? = []

    /// 默认账户为本账户的待办。
    @Relationship(deleteRule: .nullify, inverse: \Todo.account)
    var todos: [Todo]? = []

    // MARK: - 初始化

    init() {}

    // MARK: - 便捷计算属性（不参与持久化）

    var kind: AccountKind {
        get { AccountKind(raw: kindRaw) ?? .cash }
        set { kindRaw = newValue.raw }
    }

    var initialBalanceMoney: Money {
        get { Money(cents: initialBalance) }
        set { initialBalance = newValue.cents }
    }

    /// 名称兜底：空名不显示成一片空白（种子数据异常时的防御）。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }

    /// 是否可被选为记账账户（未归档）。
    var isSelectable: Bool { !isArchived }

    /// 图标名（跟随账户类型）。
    var symbolName: String { kind.symbolName }

    /// 是否存在任何关联账目（删除降级为归档的判据，R-ACC-2）。
    var hasAnyEntries: Bool {
        let outgoing = entries?.isEmpty == false
        let incoming = incomingTransfers?.isEmpty == false
        return outgoing || incoming
    }
}
