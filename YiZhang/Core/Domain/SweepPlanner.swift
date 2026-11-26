//
//  SweepPlanner.swift
//  一账 / Core / Domain
//
//  职责：结算扫描的**决策**部分——输入订阅快照 + 今天，输出"要写哪几笔账、日期推进到哪天"。
//  纯函数、零 IO、零数据库，因此 R-SUB-3/4/5/6/7/8 的全部规则可以在没有 ModelContainer 的
//  情况下 100% 单测（架构 §4.2 做法 B 的价值最高的一处边界）。
//
//  为什么把决策与落库拆开（架构 §5.1 两阶段）：
//  ① 决策是纯计算，出错只会在单测里暴露，不会产出脏数据；
//  ② 落库必须在 MainActor（iOS 17 后台 context 写入后 `@Query` 不保证刷新，风险 R6）；
//  ③ 决策可以离线复算——线上出问题时把快照打到日志里就能完整重放，不依赖数据库状态。
//
//  四条容易写错、这里刻意写成"显式分支"的地方：
//  ① **应扣日 vs 今天**：`occurredDay` 永远是 `nextBillingDay`（沿补漏循环逐期推进），
//     不能用 today，否则用户三个月没开 App，三笔账会全落在今天，月报直接错乱（R-SUB-4①）。
//  ② **cursor 必须无条件推进**：即使该期被 suppress、或幂等键已存在、或金额为 0，
//     日期也要往前走，否则补漏循环死循环（这是本文件最危险的 bug 面）。
//  ③ **24 笔上限按"笔"计数、跨订阅合计**，命中后该订阅打标并停下，其余订阅继续。
//  ④ **锚定日不漂移**：每期都用 `CycleAdvancer` + `billingAnchorDay` 推进，
//     1/31 → 2/28 之后下一期仍是 3/31（R-SUB-8）。
//

import Foundation

/// 结算扫描计划器。
enum SweepPlanner {

    /// 单次扫描最多生成多少笔（R-SUB-5）。
    static let defaultLimit = 24

    /// 订出扫描计划。
    ///
    /// - Parameters:
    ///   - snapshots: 候选订阅快照（已由查询层筛过 `status == active && 已到期`，本函数仍会重复校验，
    ///     因为它是纯函数，不应该信任调用方）。
    ///   - today: 设备本地时区的今天（R-SUB-1）。
    ///   - existingKeys: 账目表里已存在的幂等键（幂等第 2 层的前置批量取数）。
    ///   - limit: 单次上限，默认 24。
    /// - Returns: 完整计划（账目动作 / 日期推进 / 待续费提示 / 截断订阅）。
    static func plan(
        snapshots: [SubscriptionSnapshot],
        today: DateOnly,
        existingKeys: Set<String>,
        limit: Int = defaultLimit
    ) -> SweepPlan {

        var plan = SweepPlan()
        guard today.key > 0 else { return plan }

        let cap = max(limit, 1)
        var seenSubscriptionIDs = Set<UUID>()

        for snapshot in snapshots {
            // 幂等：一次扫描不重复处理同一订阅（调用方可能传重复快照）
            guard seenSubscriptionIDs.insert(snapshot.id).inserted else { continue }
            guard snapshot.nextBillingDay > 0 else { continue }

            // R-SUB-6：不自动续费 → 只产出"待续费"提示，绝不生成账目，也不推进日期
            // （日期要等用户点"已续费"才推进，否则"待续费"状态会立刻消失，用户就再看不到提醒了）
            if snapshot.status == .active, !snapshot.autoRenew {
                if snapshot.nextBillingDay <= today.key, !snapshot.isInTrial(on: today) {
                    plan.notices.append(
                        RenewalNotice(
                            subscriptionID: snapshot.id,
                            name: snapshot.name,
                            dueDay: snapshot.nextBillingDay,
                            amount: snapshot.amount
                        )
                    )
                }
                continue
            }

            // R-SUB-3 其余条件（最便宜的先判）
            guard snapshot.status == .active, snapshot.autoRenew else { continue }
            guard snapshot.nextBillingDay <= today.key else { continue }
            // E-1：试用期内不生成任何账目（nextBillingDay 应等于 trialEndDay）
            guard !snapshot.isInTrial(on: today) else { continue }

            var cursor = DateOnly(key: snapshot.nextBillingDay)
            var lastCycleKey: String?
            /// 已经"写进计划"的下次扣费日（最后一条 action 携带的那个值）。
            /// 循环结束时只要 cursor 比它更靠后，就必须补一条 advance——否则
            /// `nextBillingDay` 会停在一个已经过去的周期上（见文件末尾的注释）。
            var scheduledNextDay = snapshot.nextBillingDay
            var truncated = false

            // R-SUB-5：补漏循环，直到 nextBillingDay > today
            while cursor.key > 0, cursor.key <= today.key {
                let cycleKey = snapshot.cycleKey(for: cursor)
                let uniqueKey = snapshot.uniqueKey(for: cursor)
                let nextDay = snapshot.advanced(from: cursor)

                // 防御：推进不动就立刻退出，绝不允许死循环
                guard nextDay.key > cursor.key else { break }

                lastCycleKey = cycleKey

                let isSuppressed = snapshot.suppressedCycles.contains(cycleKey)
                let alreadyExists = existingKeys.contains(uniqueKey)

                if alreadyExists {
                    // 幂等命中：跳过该期，但日期继续推进
                    plan.skippedDuplicateCount += 1
                    cursor = nextDay
                    continue
                }
                if isSuppressed {
                    // R-SUB-DEL A：该周期不再生成，日期继续推进
                    cursor = nextDay
                    continue
                }
                if snapshot.amount <= 0 {
                    // E-9：金额为 0 只保留提醒，不生成账目，但日期必须推进
                    cursor = nextDay
                    continue
                }
                if plan.actions.count >= cap {
                    // 24 笔上限：停在当前未处理的这一期，日期推进到它，下次扫描从这里继续
                    truncated = true
                    break
                }

                plan.actions.append(
                    SweepAction(
                        subscriptionID: snapshot.id,
                        subscriptionName: snapshot.name,
                        occurredDay: cursor.key,
                        amount: snapshot.amount,
                        categoryID: snapshot.categoryID,
                        accountID: snapshot.accountID,
                        cycleKey: cycleKey,
                        uniqueKey: uniqueKey,
                        nextBillingDayAfter: nextDay.key,
                        // F-SUB-13：窗口判定用**应扣日**（`cursor.key`，不是今天）。
                        // `today` 是本函数的入参，所以这里天然满足架构 R7（不许读系统时钟）：
                        // 冷启动补漏 60 天前的账目时，它们一律 `confirmed`。
                        confirmRaw: EntryConfirmation.forSubscription(
                            occurredDay: cursor.key,
                            today: today
                        ).raw
                    )
                )
                scheduledNextDay = nextDay.key
                cursor = nextDay
            }

            if truncated {
                plan.truncatedSubscriptionIDs.append(snapshot.id)
                continue
            }

            // 日期推进：**只要 cursor 走过了最后一条已排期的账目，就要补一条 advance**。
            //
            // 这里不能写成"本轮没生成任何账目才推进"——一轮里完全可能
            // "先生成 1 笔、后面跟着一串幂等命中或被抑制的期"，此时日期只被那条 action
            // 带到了下一期，剩下的跳过期就丢了。真实后果（T14 B 分支触发）：
            // 回退到 2/28 后重放 → 生成 2/28 → 3/31…10/31 全部幂等命中 →
            // `nextBillingDay` 会留在 3/31（已经过去），而且因为永远生成不出新账目，
            // 它会一直停在那儿，用户看到"下次扣费日"是半年前。
            //
            // `scheduledNextDay` 保证正常路径下不会多写一条（值相同，落库等价）。
            if cursor.key != scheduledNextDay {
                plan.advances.append(
                    SubscriptionAdvance(
                        subscriptionID: snapshot.id,
                        nextBillingDay: cursor.key,
                        lastCycleKey: lastCycleKey
                    )
                )
            }
        }

        return plan
    }
}
