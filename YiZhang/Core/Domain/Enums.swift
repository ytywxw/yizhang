//
//  Enums.swift
//  一账 / Core / Domain
//
//  职责：全项目业务枚举的唯一声明处，以及 `String raw` 映射。
//
//  为什么枚举不直接落库：
//  ① iOS 17 上 `#Predicate` 对 `RawRepresentable` 枚举支持不稳定（`type == .expense` 常编译失败），
//     `typeRaw == "expense"` 永远可靠；
//  ② CloudKit 同步时自定义 `Codable` 可能退化为不透明二进制块，标量 `String` 不会；
//  ③ 导出（CSV/JSON）零转换。
//
//  因此模型的字段一律是 `xxxRaw: String`，通过本文件的 `init?(raw:)` / `var raw` 双向转换；
//  模型上的便捷计算属性（如 `LedgerEntry.type`）负责把这层转换藏起来。
//
//  本文件是纯 Swift：不 import SwiftData / SwiftUI。
//

import Foundation

// MARK: - 账目类型

/// 账目类型（PRD 3.2.1）。`transfer` 无分类，使用内置「转账」占位分类。
enum EntryType: String, CaseIterable, Codable, Sendable {
    case expense
    case income
    case transfer

    /// 落库用的字符串值。
    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .expense: return "支出"
        case .income: return "收入"
        case .transfer: return "转账"
        }
    }

    var isExpense: Bool { self == .expense }

    var isIncome: Bool { self == .income }

    var isTransfer: Bool { self == .transfer }
}

// MARK: - 账目来源

/// 账目来源（PRD 3.2.1），决定详情页「来自」的展示与删除分支。
enum EntrySource: String, CaseIterable, Codable, Sendable {
    case manual
    case todo
    case subscription

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .manual: return "手动"
        case .todo: return "待办"
        case .subscription: return "订阅"
        }
    }

    /// 是否需要在列表行上显示来源徽章（手动记账不显示）。
    var needsBadge: Bool { self != .manual }
}

// MARK: - 账户类型

/// 账户类型（PRD 3.2.2）。V1.0 预置 5 个账户。
enum AccountKind: String, CaseIterable, Codable, Sendable {
    case cash
    case debit
    case credit
    case alipay
    case wechat
    case other

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .cash: return "现金"
        case .debit: return "储蓄卡"
        case .credit: return "信用卡"
        case .alipay: return "支付宝"
        case .wechat: return "微信"
        case .other: return "其他"
        }
    }

    /// SF Symbols 名称（纯字符串，不涉及 SwiftUI）。
    var symbolName: String {
        switch self {
        case .cash: return "banknote"
        case .debit: return "creditcard"
        case .credit: return "creditcard.fill"
        case .alipay: return "a.circle"
        case .wechat: return "w.circle"
        case .other: return "tray.full"
        }
    }
}

// MARK: - 周期单位

/// 订阅周期单位（PRD 4.1）。与 `cycleValue` 组合表达「每 N 天 / 每 N 周 / 每 N 月 / 每季 / 每年」。
enum CycleUnit: String, CaseIterable, Codable, Sendable {
    case day
    case week
    case month
    case quarter
    case year

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .day: return "天"
        case .week: return "周"
        case .month: return "月"
        case .quarter: return "季"
        case .year: return "年"
        }
    }

    /// 推进时折算成"月"的倍数；`day` / `week` 不走月推进，返回 0。
    var monthsMultiplier: Int {
        switch self {
        case .month: return 1
        case .quarter: return 3
        case .year: return 12
        case .day, .week: return 0
        }
    }

    /// 是否为"自然月推进"类周期（决定使用 `CycleAdvancer` 的期末对齐分支）。
    var isMonthBased: Bool { monthsMultiplier > 0 }

    /// `cycleValue == 1` 时返回 "每月"，否则 "每 2 个月" / "每 45 天"。
    func cycleText(value: Int) -> String {
        let step = max(value, 1)
        if step == 1 { return "每\(displayName)" }
        return "每 \(step) \(displayName)"
    }

    /// 订阅行上的后缀文本，如 "月" / "2 个月" / "45 天"，配合 "¥25 / " 使用。
    func suffixText(value: Int) -> String {
        let step = max(value, 1)
        return step == 1 ? displayName : "\(step) \(displayName)"
    }
}

// MARK: - 待办优先级

/// 待办优先级（PRD 5.1），默认 `none`。
enum TodoPriority: String, CaseIterable, Codable, Sendable {
    case none
    case low
    case medium
    case high

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .none: return "无"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    /// 排序权重，越大越靠前（列表排序用）。
    var sortWeight: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    var isHighlighted: Bool { self == .high || self == .medium }
}

// MARK: - 重复规则

/// 待办重复规则（PRD 5.4 R-TODO-R3），配合 `repeatInterval` 表达「每 N 周 / 每 N 月」。
enum RepeatRule: String, CaseIterable, Codable, Sendable {
    case none
    case daily
    case weekly
    case monthly
    case yearly

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .none: return "不重复"
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .yearly: return "每年"
        }
    }

    /// 该规则是否需要 `repeatInterval`（`none` 不需要）。
    var supportsInterval: Bool { self != .none }

    /// 推进用的周期单位；`none` 返回 nil。
    var cycleUnit: CycleUnit? {
        switch self {
        case .none: return nil
        case .daily: return .day
        case .weekly: return .week
        case .monthly: return .month
        case .yearly: return .year
        }
    }
}

// MARK: - 订阅状态

/// 订阅状态机（PRD 附录 A.2）。
enum SubscriptionStatus: String, CaseIterable, Codable, Sendable {
    case active
    case paused
    case cancelled

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .active: return "生效中"
        case .paused: return "已暂停"
        case .cancelled: return "已取消"
        }
    }

    /// 只有 `active` 才可能生成账目（还需 `autoRenew` 等条件，见 `SweepPlanner`）。
    var isGenerating: Bool { self == .active }
}

// MARK: - 待办状态

/// 待办状态（PRD 5.1）。刻意没有 `pending_confirmation`：
/// 「待确认」是纯 UI 瞬态，落库会留下"永远等确认"的僵尸待办。
enum TodoStatus: String, CaseIterable, Codable, Sendable {
    case open
    case done

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .open: return "未完成"
        case .done: return "已完成"
        }
    }

    var isDone: Bool { self == .done }
}

// MARK: - 外观

/// 外观偏好（`AppSettings.appearanceRaw`）。
enum Appearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}
