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

// MARK: - 账目确认状态

/// 账目确认状态（V1.1 F-SUB-13）。
///
/// 只有订阅自动生成的**近期**账目才会是 `pending`（见 PRD 2.2 的生成规则），
/// 手动记账与待办完成一律 `confirmed`——待办完成的那次确认本身就是一次人工确认。
///
/// 为什么是 `String` raw 而不是 `Bool`：留出"未来可能的第三态"的空间（如 `ignored`），
/// 且与全项目"枚举一律落 `xxxRaw: String`"的约定一致（iOS 17 的 `#Predicate` 对枚举不稳）。
///
/// **计入口径**：`pending` 计入余额与一切统计（PRD 2.3-1）。它只是一个"我还没核对"的标记，
/// 不是"这笔钱不存在"。
enum EntryConfirmation: String, CaseIterable, Codable, Sendable {
    case confirmed
    case pending

    /// 落库用的字符串值。
    var raw: String { rawValue }

    init?(raw: String) {
        self.init(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .confirmed: return "已确认"
        case .pending: return "待确认"
        }
    }

    var isPending: Bool { self == .pending }
}

// MARK: - 「待确认」的判定规则（V1.1 F-SUB-13）

/// 订阅账目「要不要等用户核对」的**唯一**判定实现。
///
/// 为什么规则放在 Domain 的枚举扩展里，而不是放进 `LedgerWriter` 或某个 Service：
/// ① `LedgerWriter` **禁止包含业务规则**（架构 A3），它只负责"安全地落库"；
/// ② 这条规则有**两条写入路径**——结算扫描（`SweepCoordinator`）与补录
///    （`SubscriptionService.backfill` → `LedgerService.validated`）。若规则写两份，
///    两条路径迟早分叉：一条给 pending、另一条给 confirmed，用户看到的徽标就会
///    随"这笔账是怎么来的"而随机变化，而这种分叉单测很难发现。
/// 所以：**规则只写一处，两处调用**（`SweepAction.confirmRaw` 与 `LedgerService.validated`）。
///
/// 窗口语义（PRD 2.2）：应扣日 `>= 今天 - 7 天` 即为待确认，也就是"今天与往前 7 天"
/// （含首尾共 8 个自然日）。边界断言：今天 → pending；`-7` 天 → pending；
/// `-8` 天 → confirmed（见 `EntryConfirmationTests`）。
/// 之所以取 7 天这个量级：用户一般会在一周内核对一次账单；再久远的账目如果还是
/// 待确认状态，等于把"提醒"变成"噪音"，用户只会学会无视那个徽标。
extension EntryConfirmation {

    /// 「待确认」窗口：应扣日距今不超过这么多天（含今天）。
    static let pendingWindowDays = 7

    /// 订阅在**某一期**上应该处于什么确认状态。
    ///
    /// - Parameters:
    ///   - occurredDay: 该期的应扣日 `yyyyMMdd`（**不是今天**，见 R-SUB-4①）。
    ///   - today: 设备本地时区的今天。**必须由调用方注入**（架构 R7）：冷启动补漏时
    ///     会一次性生成几十天前的历史账目，如果拿"写入时刻"当基准，那些历史账目
    ///     会被全部标成 pending，用户一打开 App 就看到几十笔待确认。
    /// - Returns: 应扣日在窗口内 → `.pending`；更早 → `.confirmed`。
    ///
    /// 两个 `guard` 都是必要的：
    /// - `occurredDay > 0`：`0` 是"没有日期"的哨兵值，不能拿它跟窗口比较；
    /// - `today.key > 0`：`DateOnly.zero` 表示"今天未知"。此时窗口下界会退化成 `0`，
    ///   于是任何账目都会被判成 pending——宁可退回 `confirmed`（用户不用去核对），
    ///   也不能凭一个不存在的日期给全库账目打标。
    static func forSubscription(occurredDay: Int32, today: DateOnly) -> EntryConfirmation {
        guard occurredDay > 0 else { return .confirmed }
        guard today.key > 0 else { return .confirmed }
        let windowStart = today.adding(days: -pendingWindowDays).key
        return occurredDay >= windowStart ? .pending : .confirmed
    }
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
