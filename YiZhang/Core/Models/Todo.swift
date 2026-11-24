//
//  Todo.swift
//  一账 / Core / Models
//
//  职责：待办模型（PRD 5.1 / 架构 §3.2）。纯数据 + 便捷计算属性。
//
//  两个刻意的设计取舍：
//  1. **没有 `pending_confirmation` 状态**：`statusRaw` 只有 open / done。
//     "待确认"是纯 UI 瞬态（`TodoCompletionViewModel` 里的内存状态），
//     落库会在"确认条弹出时 App 被杀"的场景留下永远等确认的僵尸待办。
//  2. **没有 `isSystemGenerated` / `sourceSubscriptionID` 落库字段**（架构 §3.7 D4）。
//     待办页顶部的"订阅扣费（未来 30 天）"只读分组由 `SubscriptionOverview` 实时派生，
//     落库会造出与 Subscription 重复的真相源。
//
//  CloudKit 形状约束同 `LedgerEntry`。
//

import Foundation
import SwiftData

/// 待办（一件事）。
@Model
final class Todo {

    // MARK: - 标量字段

    var id: UUID = UUID()

    /// 标题（≤ 60 字）。
    var title: String = ""

    /// 备注（≤ 500 字）。
    var note: String = ""

    /// 截止日，`yyyyMMdd`。**0 = 无日期**（归入「无日期」分组）。
    var dueDay: Int32 = 0

    /// 截止时间：当日分钟数（0…1439），**-1 = 无具体时间**。
    var dueTimeMinutes: Int32 = -1

    /// 是否开启花销（开启后才显示金额 / 分类 / 账户）。
    var hasExpense: Bool = false

    /// 预计金额（分）。仅在 `hasEstimatedAmount == true` 时有意义。
    var estimatedAmount: Int64 = 0

    /// 区分"未填金额"与"填了 0"（PRD 5.1：金额可为空）。
    var hasEstimatedAmount: Bool = false

    /// `TodoPriority` 的 raw 值：none / low / medium / high。
    var priorityRaw: String = TodoPriority.none.raw

    /// `RepeatRule` 的 raw 值：none / daily / weekly / monthly / yearly。
    var repeatRuleRaw: String = RepeatRule.none.raw

    /// 重复间隔（每 N 周 / 每 N 月 / 每 N 天）。
    var repeatInterval: Int = 1

    /// `TodoStatus` 的 raw 值：open / done。
    var statusRaw: String = TodoStatus.open.raw

    /// 完成时间（`status == done` 时必填）。
    var completedAt: Date? = nil

    /// 提醒日，`yyyyMMdd`。0 = 无提醒。
    var reminderDay: Int32 = 0

    /// 提醒时间：当日分钟数，**-1 = 使用默认 09:00**。
    var reminderMinutes: Int32 = -1

    /// 由本待办生成的账目 id（回写，R-TODO-3）。
    var linkedEntryID: UUID? = nil

    var createdAt: Date = Date(timeIntervalSince1970: 0)

    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: - 关系

    var category: Category? = nil

    var account: Account? = nil

    /// V1.1 预留：派生自哪个订阅（V1.0 的订阅只读待办项不落库）。
    var sourceSubscription: Subscription? = nil

    /// 由本待办生成的账目（反向关系在 `LedgerEntry.linkedTodos` 声明）。
    var linkedEntry: LedgerEntry? = nil

    // MARK: - 初始化

    init() {}

    // MARK: - 便捷计算属性（不参与持久化）

    var status: TodoStatus {
        get { TodoStatus(raw: statusRaw) ?? .open }
        set { statusRaw = newValue.raw }
    }

    var priority: TodoPriority {
        get { TodoPriority(raw: priorityRaw) ?? .none }
        set { priorityRaw = newValue.raw }
    }

    var repeatRule: RepeatRule {
        get { RepeatRule(raw: repeatRuleRaw) ?? .none }
        set { repeatRuleRaw = newValue.raw }
    }

    /// 截止自然日；`dueDay == 0` 时返回 nil（无日期）。
    var dueDate: DateOnly? {
        get { dueDay > 0 ? DateOnly(key: dueDay) : nil }
        set { dueDay = newValue?.key ?? 0 }
    }

    /// 提醒自然日；`reminderDay == 0` 时返回 nil。
    var reminderDate: DateOnly? {
        get { reminderDay > 0 ? DateOnly(key: reminderDay) : nil }
        set { reminderDay = newValue?.key ?? 0 }
    }

    /// 截止时刻（仅供 `DatePicker` 绑定；无截止日时回落到今天）。
    var dueAt: Date {
        get { dueDate?.date ?? DateOnly(Date()).date }
        set { dueDate = DateOnly(newValue) }
    }

    /// 预计金额值类型；未填金额时返回 nil（区分"未填"与"填了 0"）。
    var estimatedMoney: Money? {
        get { hasEstimatedAmount ? Money(cents: estimatedAmount) : nil }
        set {
            if let value = newValue {
                estimatedAmount = value.cents
                hasEstimatedAmount = true
            } else {
                estimatedAmount = 0
                hasEstimatedAmount = false
            }
        }
    }

    /// 是否已完成。
    var isDone: Bool { status == .done }

    /// 是否仍未完成。
    var isOpen: Bool { status == .open }

    /// 是否有截止日。
    var hasDueDate: Bool { dueDay > 0 }

    /// 是否已逾期（未完成 + 有截止日 + 截止日早于今天）。R-TODO-R6。
    func isOverdue(on today: DateOnly = DateOnly(Date())) -> Bool {
        guard status == .open, let due = dueDate else { return false }
        return due < today
    }

    /// 是否已记账（回写 id 存在）。
    var hasLinkedEntry: Bool { linkedEntryID != nil }

    /// 名称兜底。
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名待办" : trimmed
    }

    /// 重复规则文本，如"每 2 周"、"不重复"。
    var repeatText: String {
        guard repeatRule != .none, let unit = repeatRule.cycleUnit else { return "不重复" }
        return unit.cycleText(value: repeatInterval)
    }
}
