//
//  Subscription.swift
//  一账 / Core / Models
//
//  职责：订阅模型（PRD 4.1 / 架构 §3.2）。纯数据 + 便捷计算属性。
//
//  三个关键字段的语义（务必别搞错）：
//  - `billingAnchorDay`：**期末对齐锚定日**（R-SUB-8）。推进时始终以它为基准，
//    因此 1/31 → 2/28 之后，下下次是 3/31 而不是 3/28。锚定日只在"新建 / 用户手改
//    nextBillingDay"时重置，改周期与结算推进都不动它。
//  - `nextBillingDay`：下次扣费日，`0` 是哨兵表示"无"（已取消，E-3）。
//    模型里刻意没有一个 `Int32?`，谓词全是整数比较，消除 iOS 17 对 Optional 谓词的崩溃面。
//  - `suppressedCycles`：用户"只删这笔账"后被抑制的周期键（R-SUB-DEL A）。
//
//  CloudKit 形状约束同 `LedgerEntry`。`suppressedCycles` 若在 V1.1 遇到云端数组兼容问题，
//  降级为 `suppressedCyclesCSV: String`（架构 §3.7 D5）。
//

import Foundation
import SwiftData

/// 订阅（周期性自动扣费）。
@Model
final class Subscription {

    // MARK: - 标量字段

    var id: UUID = UUID()

    /// 名称（≤ 30 字，业务层校验）。
    var name: String = ""

    /// 每期扣费金额（分）。允许 0（E-9：金额为 0 时不生成账目，仅保留提醒）。
    var amount: Int64 = 0

    /// V1.0 固定 "CNY"，字段预留不暴露 UI。
    var currency: String = "CNY"

    /// `CycleUnit` 的 raw 值：day / week / month / quarter / year。
    var cycleUnitRaw: String = CycleUnit.month.raw

    /// 周期倍数，1…366。`month×2` = 每 2 个月，`day×45` = 每 45 天。
    var cycleValue: Int = 1

    /// 期末对齐锚定日，1…31。新建时 = `firstBillingDay.day`。防漂移的关键字段（R-SUB-8）。
    var billingAnchorDay: Int = 1

    /// 首次扣费日，`yyyyMMdd`。允许过去日期（E-5 补录）。
    var firstBillingDay: Int32 = 0

    /// 下次扣费日，`yyyyMMdd`。**0 = 无**（已取消，E-3）。
    var nextBillingDay: Int32 = 0

    /// 是否自动续费。`false` 时到期只提醒不自动记账（R-SUB-6）。
    var autoRenew: Bool = true

    /// 免费试用结束日，`yyyyMMdd`。0 = 无试用（E-1）。
    var trialEndDay: Int32 = 0

    var note: String = ""

    /// 图标名，空则按名称首字生成彩色圆底（展示层负责）。
    var iconName: String = ""

    /// `#RRGGBB`，空则使用品牌色板默认值。
    var colorHex: String = ""

    /// `SubscriptionStatus` 的 raw 值：active / paused / cancelled。
    var statusRaw: String = SubscriptionStatus.active.raw

    /// 提前几天提醒：0（当天）/ 1 / 3 / 7。
    var reminderDays: Int = 1

    /// 被"只删这笔账"抑制的周期键列表（R-SUB-DEL A）。默认空数组而非 nil，便于追加。
    var suppressedCycles: [String]? = []

    /// 结算扫描最后处理到的周期键，辅助幂等排查。
    var lastSweptCycleKey: String? = nil

    var createdAt: Date = Date(timeIntervalSince1970: 0)

    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: - 关系

    /// 默认分类「订阅服务」（R-CAT-4）。
    var category: Category? = nil

    /// 扣费账户，默认上次使用。
    var account: Account? = nil

    /// 由本订阅派生的待办（V1.1 预留；V1.0 的订阅只读待办项是实时派生的，不落库，见 §3.7 D4）。
    @Relationship(deleteRule: .nullify, inverse: \Todo.sourceSubscription)
    var derivedTodos: [Todo]? = []

    // MARK: - 初始化

    init() {}

    // MARK: - 便捷计算属性（不参与持久化）

    var cycleUnit: CycleUnit {
        get { CycleUnit(raw: cycleUnitRaw) ?? .month }
        set { cycleUnitRaw = newValue.raw }
    }

    var status: SubscriptionStatus {
        get { SubscriptionStatus(raw: statusRaw) ?? .active }
        set { statusRaw = newValue.raw }
    }

    var amountMoney: Money {
        get { Money(cents: amount) }
        set { amount = newValue.cents }
    }

    /// 下次扣费自然日；`nextBillingDay == 0` 时返回 nil（E-3 已取消）。
    var nextBillingDate: DateOnly? {
        get { nextBillingDay > 0 ? DateOnly(key: nextBillingDay) : nil }
        set { nextBillingDay = newValue?.key ?? 0 }
    }

    /// 首次扣费自然日；未设置时返回 nil。
    var firstBillingDate: DateOnly? {
        get { firstBillingDay > 0 ? DateOnly(key: firstBillingDay) : nil }
        set { firstBillingDay = newValue?.key ?? 0 }
    }

    /// 试用结束自然日；无试用返回 nil。
    var trialEndDate: DateOnly? {
        get { trialEndDay > 0 ? DateOnly(key: trialEndDay) : nil }
        set { trialEndDay = newValue?.key ?? 0 }
    }

    /// 下次扣费时刻（仅供 `DatePicker` 绑定；无值时回落到今天）。
    var nextBillingAt: Date {
        get { nextBillingDate?.date ?? DateOnly(Date()).date }
        set { nextBillingDate = DateOnly(newValue) }
    }

    /// 被抑制周期的集合视图（写入时统一走它，避免 `[String]?` 的 nil 分支散落各处）。
    var suppressedCycleSet: Set<String> {
        get { Set(suppressedCycles ?? []) }
        set { suppressedCycles = Array(newValue) }
    }

    /// 是否处于试用中（E-1）。
    func isInTrial(on today: DateOnly = DateOnly(Date())) -> Bool {
        trialEndDay > 0 && today.key < trialEndDay
    }

    /// 是否为"待续费"状态（R-SUB-6：不自动续费且已到期）。
    func isAwaitingRenewal(on today: DateOnly = DateOnly(Date())) -> Bool {
        guard status == .active, !autoRenew, let next = nextBillingDate else { return false }
        return next <= today
    }

    /// 名称兜底。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名订阅" : trimmed
    }

    /// 周期文本，如"每月"/"每 2 个月"/"每 45 天"。
    var cycleText: String { cycleUnit.cycleText(value: cycleValue) }

    /// 行内价格后缀，如"¥25 / 月"。
    var pricePerCycleText: String {
        "\(amountMoney.formatted()) / \(cycleUnit.suffixText(value: cycleValue))"
    }
}
