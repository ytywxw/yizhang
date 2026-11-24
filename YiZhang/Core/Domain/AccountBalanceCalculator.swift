//
//  AccountBalanceCalculator.swift
//  一账 / Core / Domain
//
//  职责：R-ACC-1 账户余额的唯一实现——`期初 - Σ支出 + Σ收入 - Σ转出 + Σ转入`，只读、纯函数。
//
//  为什么余额必须是"算出来的"而不是"存下来的"：
//  存余额就要维护一致性——新增账目、编辑、软删、撤销、订阅扫描、导出恢复，每一步都得同步改数字，
//  漏一步用户就会看到"余额和流水对不上"，而且这种错是累积的、极难定位。
//  算余额的代价只是每次进入账户页扫一遍该账户的流水（≤ 数千条，几毫秒）。
//
//  为什么用 DTO 而不是 `@Model`（架构 §4.2 做法 B）：
//  本文件属于 Domain，不 import SwiftData；输入是 4 个标量的 `Movement`，
//  因此余额公式的全部边界（转账两侧、软删、收入/支出方向）都能在 0 个数据库的情况下单测。
//
//  信用卡（R-ACC-3）：公式与储蓄卡一致，欠款表现为负余额；
//  `kindRaw` 只是让调用方知道"这是信用卡，别把负数当成错误"，
//  本计算器刻意不为信用卡做特殊数学——那会让"余额"出现两种含义。
//

import Foundation

/// 账户余额计算器。
enum AccountBalanceCalculator {

    /// 账户输入（只含计算需要的字段）。
    struct AccountSnapshot: Hashable, Sendable {
        let id: UUID
        /// 期初余额（分）。
        let initialBalanceCents: Int64
        /// `AccountKind` 的 raw 值（仅用于调用方判断展示口径，不参与数学）。
        let kindRaw: String

        init(id: UUID, initialBalanceCents: Int64, kindRaw: String = AccountKind.cash.raw) {
            self.id = id
            self.initialBalanceCents = initialBalanceCents
            self.kindRaw = kindRaw
        }

        var kind: AccountKind { AccountKind(raw: kindRaw) ?? .cash }

        var initialBalance: Money { Money(cents: initialBalanceCents) }
    }

    /// 一条资金流动（账目在该账户上的投影）。
    struct Movement: Hashable, Sendable {
        /// 金额（分），总是正数；方向由 `typeRaw` + 账户角色决定。
        let amountCents: Int64
        /// `EntryType` 的 raw 值。
        let typeRaw: String
        /// 付款 / 收入账户 id。
        let accountID: UUID?
        /// 转入账户 id（仅转账）。
        let toAccountID: UUID?
        /// 是否已软删（软删记录不参与余额）。
        let isDeleted: Bool

        init(
            amountCents: Int64,
            typeRaw: String,
            accountID: UUID? = nil,
            toAccountID: UUID? = nil,
            isDeleted: Bool = false
        ) {
            self.amountCents = amountCents
            self.typeRaw = typeRaw
            self.accountID = accountID
            self.toAccountID = toAccountID
            self.isDeleted = isDeleted
        }

        var type: EntryType { EntryType(raw: typeRaw) ?? .expense }
    }

    /// 计算余额。
    ///
    /// - Parameters:
    ///   - account: 账户（期初余额 + id）。
    ///   - movements: 与该账户相关的全部账目（付款或转入任一侧）。
    /// - Returns: 余额（分）。可能为负（信用卡欠款 / 期初为负）。
    static func balance(account: AccountSnapshot, movements: [Movement]) -> Money {
        var total = Money(cents: account.initialBalanceCents)

        for movement in movements {
            guard !movement.isDeleted else { continue }
            guard let signed = signedDelta(for: movement, accountID: account.id) else { continue }
            total = total + signed
        }
        return total
    }

    /// 单条流动对某账户的带符号影响；与该账户无关时返回 nil。
    ///
    /// 四种情况穷举（少一种就会算错余额，这是本文件最容易出错的地方）：
    /// - 支出 + 我是付款账户 → 负
    /// - 收入 + 我是收款账户 → 正
    /// - 转账 + 我是转出账户 → 负
    /// - 转账 + 我是转入账户 → 正
    ///
    /// 特殊：转账的两侧 id 相同时（脏数据）只算一次转出，避免"自己转给自己把余额翻倍"。
    static func signedDelta(for movement: Movement, accountID: UUID) -> Money? {
        switch movement.type {
        case .expense:
            guard movement.accountID == accountID else { return nil }
            return Money(cents: -movement.amountCents)

        case .income:
            guard movement.accountID == accountID else { return nil }
            return Money(cents: movement.amountCents)

        case .transfer:
            let isSource = movement.accountID == accountID
            let isTarget = movement.toAccountID == accountID
            if isSource && isTarget { return Money(cents: -movement.amountCents) }
            if isSource { return Money(cents: -movement.amountCents) }
            if isTarget { return Money(cents: movement.amountCents) }
            return nil
        }
    }
}
