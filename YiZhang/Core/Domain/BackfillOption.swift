//
//  BackfillOption.swift
//  一账 / Core / Domain
//
//  职责：补录历史订阅（E-5）的**决策值**与**周期枚举**，纯函数、零 IO。
//
//  为什么补录要拆成"选项 + 单独动作"两段（而不是保存时顺手补上）：
//  E-5 明文规定「默认不补，用户勾选后才补」。补账会污染历史月份的统计，
//  而统计是这个 App 的信任基础——多出一笔用户没花的钱，比少一笔更严重。
//  所以保存订阅只**返回**一个 `BackfillOption`（可补多少期、默认 0 期），
//  真正写账由调用方显式再调一次 `SubscriptionService.backfill(subscriptionID:cycles:)`。
//
//  为什么要给补录封顶 12 期（`maximumCycles`）：
//  ① 用户填一个 3 年前的首次扣费日时，一次补 36 笔会让当月/当季统计瞬间失真；
//  ② 每期都要走幂等查询 + 插入，无上限会让"保存订阅"变成一次不可控的批量写；
//  ③ 12 期覆盖"一年没打开 App"这个真实场景，超出部分用户手动记更像诚实的做法。
//
//  本文件是纯 Swift：不 import SwiftData / SwiftUI。
//

import Foundation

// MARK: - 历史周期枚举

/// 补录用的历史周期枚举器。
enum BackfillPlanner {

    /// 枚举从 `nextBillingDay` 起、不晚于今天的每一期应扣日。
    ///
    /// 为什么起点是 `nextBillingDay` 而不是 `firstBillingDay`：
    /// `nextBillingDay` 的语义就是「**还没生成账目的那一期**」——
    /// - 新建时首次扣费日填在过去 → `nextBillingDay == firstBillingDay`，于是从首次扣费日一直枚举到今天；
    /// - 老订阅已经结算到 10 月 → `nextBillingDay == 10/15`，8、9 月已经入账，不能再算"欠账"；
    /// - 用户把 `nextBillingDay` 校正到未来 → 返回空，因为系统认为它之后的期数都还没到期。
    ///
    /// 这样补录永远只覆盖「真的一笔都没记过的期数」，不会虚增历史统计（E-5 的初衷）。
    ///
    /// - Parameters:
    ///   - nextBillingDay: 下次扣费日（唯一未结算的那一期）；`0`（已取消）时返回空。
    ///   - anchorDay: 锚定日（R-SUB-8），推进时保持不变。
    ///   - unit: 周期单位。
    ///   - value: 周期倍数（≤ 0 按 1 处理，与 `CycleAdvancer` 一致）。
    ///   - today: 今天（只枚举不晚于今天的期数）。
    ///   - iterationLimit: 防御性上限，避免脏数据导致死循环。
    /// - Returns: 升序排列的应扣日（可能为空）。
    static func pastCycles(
        nextBillingDay: DateOnly,
        anchorDay: Int,
        unit: CycleUnit,
        value: Int,
        today: DateOnly,
        iterationLimit: Int = 400
    ) -> [DateOnly] {
        guard today.key > 0, nextBillingDay.key > 0, nextBillingDay <= today else { return [] }

        var result: [DateOnly] = []
        var cursor = nextBillingDay
        var steps = 0

        while cursor <= today, steps < iterationLimit {
            result.append(cursor)

            let next = CycleAdvancer.advance(from: cursor, unit: unit, value: value, anchorDay: anchorDay)
            // 防御：推进不动就退出，绝不进入死循环
            guard next.key > cursor.key else { break }
            cursor = next
            steps += 1
        }
        return result
    }
}

// MARK: - 补录选项

/// 保存订阅后返回给调用方的"要不要补录"选项。
///
/// 语义要点：
/// - `availableCycles` 是**可补的历史期数**，已按 12 期封顶；
/// - `defaultCycles == 0`，即默认不补（E-5）；
/// - 只是一个值，不代表已经写入任何账目。
struct BackfillOption: Hashable, Sendable {

    /// 单次补录的期数上限（E-5：只补最近 12 期以内）。
    static let maximumCycles = 12

    /// 默认补录期数：0（默认不补）。
    static let defaultCycles = 0

    let subscriptionID: UUID

    /// 可补的历史期数（1…12）。
    let availableCycles: Int

    /// 可补区间里最早的一期（UI 展示"3月25日 起"用）。
    let earliestDay: DateOnly?

    /// 可补区间里最近的一期。
    let latestDay: DateOnly?

    /// - Parameters:
    ///   - subscriptionID: 订阅 id。
    ///   - pastCycles: `BackfillPlanner.pastCycles` 的结果（升序）。
    init(subscriptionID: UUID, pastCycles: [DateOnly]) {
        let capped = Array(pastCycles.suffix(Self.maximumCycles))
        self.subscriptionID = subscriptionID
        self.availableCycles = capped.count
        self.earliestDay = capped.first
        self.latestDay = capped.last
    }

    /// 是否需要询问用户（没有可补期数时调用方不该弹任何 UI）。
    var isOffered: Bool { availableCycles > 0 }

    /// 可选期数：从 0（不补）到 `availableCycles`。
    var selectableCycles: [Int] {
        guard availableCycles > 0 else { return [Self.defaultCycles] }
        return Array(0...availableCycles)
    }

    /// 提示文案（PRD E-5 的「是否为已过去的 N 个周期补生成账目？」）。
    var promptText: String {
        guard availableCycles > 0 else { return "" }
        return "有 \(availableCycles) 个已过去的周期，要为它们补生成账目吗？"
    }

    /// 把用户选择的期数夹到合法范围（0…availableCycles）。
    func clampedCycles(_ requested: Int) -> Int {
        min(max(requested, 0), availableCycles)
    }
}
