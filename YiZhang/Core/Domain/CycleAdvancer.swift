//
//  CycleAdvancer.swift
//  一账 / Core / Domain
//
//  职责：周期推进的唯一实现（R-SUB-8「期末对齐」），纯函数、零 IO、零 `Calendar`。
//
//  核心规则：**推进时永不以"被夹紧后的日期"为基准，而以 `billingAnchorDay`（锚定日）为基准。**
//  反例（错误实现）：1/31 +1 月 → 2/28，再从 2/28 推 1 月 → 3/28 → 4/28，永久漂移。
//  正例（本实现）：  1/31 +1 月 → 2/28，再从 1/31 这个锚定日推 1 月 → 3/31。
//
//  锚定日何时重置（见架构 §5.2）：
//  | 事件                        | billingAnchorDay      |
//  | 新建订阅                    | = firstBillingDay.day |
//  | 用户手改 nextBillingDay      | = 新值.day            |
//  | 改周期（unit/value）         | 不变                  |
//  | 结算推进                    | 不变（防漂移的关键）    |
//
//  本文件是纯 Swift：不 import SwiftData / SwiftUI，也不 import Foundation 的日历能力。
//

import Foundation

/// 周期推进器。
///
/// 月推进用 `DateOnly` 的纯整数 civil 算法 + 固定天数表 + 闰年判定，
/// 因此任何时区 / locale 下结果一致，可以被 100% 单测覆盖。
enum CycleAdvancer {

    /// 以 `anchorDay` 为基准日推进一个周期。
    ///
    /// - Parameters:
    ///   - date: 起始自然日（通常是当前的 `nextBillingDay`）。
    ///   - unit: 周期单位。
    ///   - value: 周期倍数。**≤ 0 时按 1 处理**：脏数据下宁可多推一期，也不能返回原地——
    ///     返回原地会让 `SweepPlanner` 的补漏循环永远不前进（死循环），这是更坏的结果。
    ///   - anchorDay: 锚定日（1...31），目标月没有该日时取该月最后一天。
    /// - Returns: 推进后的自然日。
    static func advance(from date: DateOnly, unit: CycleUnit, value: Int, anchorDay: Int) -> DateOnly {
        let step = max(value, 1)
        guard date.key > 0 else { return date }

        switch unit {
        case .day:
            return date.adding(days: step)

        case .week:
            let (days, overflow) = 7.multipliedReportingOverflow(by: step)
            guard !overflow else { return date }
            return date.adding(days: days)

        case .month, .quarter, .year:
            let (months, overflow) = unit.monthsMultiplier.multipliedReportingOverflow(by: step)
            guard !overflow else { return date }
            let clampedAnchor = min(max(anchorDay, 1), 31)
            return DateOnly.advancingMonths(from: date, months: months, anchorDay: clampedAnchor)
        }
    }

    /// 不显式传锚定日时的自然推进：以起始日自身的日号作为锚定日。
    ///
    /// 注意这**不是**订阅结算路径——订阅必须传固定的 `billingAnchorDay`，否则会漂移。
    /// 这个方法服务非订阅场景（例如"每月提醒日"这类一次性顺延）。
    static func advance(from date: DateOnly, unit: CycleUnit, value: Int) -> DateOnly {
        advance(from: date, unit: unit, value: value, anchorDay: date.day)
    }

    /// 与上面等价、仅参数顺序不同的重载，与架构文档 §5.1 伪代码的调用写法保持一致
    /// （`advance(from:anchorDay:unit:value:)`），避免后续任务因参数顺序不同而改写。
    static func advance(from date: DateOnly, anchorDay: Int, unit: CycleUnit, value: Int) -> DateOnly {
        advance(from: date, unit: unit, value: value, anchorDay: anchorDay)
    }

    /// 把已过期的日期按周期推进到"今天之后的第一个周期日"。
    ///
    /// 服务两处：E-4（暂停恢复）与 R-TODO-R3（重复待办生成下一期）。
    /// 从 `origin` 出发连续推进，直到严格晚于 `today`；保留锚定日，因此不会漂移。
    static func advanceToFuture(
        from origin: DateOnly,
        today: DateOnly,
        unit: CycleUnit,
        value: Int,
        anchorDay: Int,
        maximumSteps: Int = 1_000
    ) -> DateOnly {
        guard origin.key > 0 else { return origin }
        var cursor = origin
        var steps = 0
        while cursor <= today && steps < maximumSteps {
            let next = advance(from: cursor, unit: unit, value: value, anchorDay: anchorDay)
            if next == cursor { return cursor }  // 防御：无法推进时立即退出，绝不进入死循环
            cursor = next
            steps += 1
        }
        return cursor
    }
}
