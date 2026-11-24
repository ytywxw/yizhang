//
//  SubscriptionSnapshot+Model.swift
//  一账 / Core / Persistence
//
//  职责：`Subscription`（`@Model`）→ `SubscriptionSnapshot`（Domain 值类型）的唯一映射。
//
//  为什么这个转换必须只有一处：
//  ① 幂等键规则（`cycleKey(for:)` / `uniqueKey(for:)`）只在 `SubscriptionSnapshot` 里实现，
//     结算扫描（`SweepCoordinator`）与订阅服务（`SubscriptionService`）都必须经由本文件拿到快照，
//     否则两边都可能"顺手"再拼一次字符串，拼错一个分隔符就整体失去幂等；
//  ② Domain 层不 import SwiftData（架构 §4.2），所以映射只能放在这里。
//

import Foundation

/// 订阅模型 → 快照。
enum SubscriptionMapper {

    /// 单个订阅 → 快照。
    ///
    /// 注意 `suppressedCycles` 是 `[String]?`，模型允许 nil；
    /// 快照里统一成 `Set<String>`（空集合），让下游判断不必再处理 nil 分支。
    static func snapshot(of subscription: Subscription) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: subscription.id,
            name: subscription.displayName,
            amount: max(subscription.amount, 0),
            statusRaw: subscription.statusRaw,
            autoRenew: subscription.autoRenew,
            nextBillingDay: subscription.nextBillingDay,
            trialEndDay: subscription.trialEndDay,
            cycleUnit: subscription.cycleUnit,
            cycleValue: subscription.cycleValue,
            anchorDay: subscription.billingAnchorDay,
            reminderDays: subscription.reminderDays,
            suppressedCycles: subscription.suppressedCycleSet,
            categoryID: subscription.category?.id,
            accountID: subscription.account?.id
        )
    }

    /// 批量映射（保持输入顺序，排序由调用方的查询决定）。
    static func snapshots(_ subscriptions: [Subscription]) -> [SubscriptionSnapshot] {
        subscriptions.map { snapshot(of: $0) }
    }
}
