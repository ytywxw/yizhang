//
//  SubscriptionOverview.swift
//  一账 / Core / Domain
//
//  职责：订阅总览的纯计算——每月固定支出折算、年度总成本、未来 N 天扣费时间轴（PRD 4.4）。
//
//  为什么必须纯函数 + 整数分：
//  "每月固定支出"是把不同周期折算到同一口径的数字，用户会拿它跟自己的工资、房租比较，
//  所以它不能随"这个月是不是闰月""这台设备的浮点行为"而变。全部用**整数运算**，
//  中间量放大成"千分之一分"（千分位）保留精度，最后一次性取整，
//  这样既没有 `Double` 的累积误差，也不会因为先取整每一条而放大偏差。
//
//  折算系数来自 PRD 4.4 的明文规定，改动它会直接改产品口径，所以写在常量里并标好出处：
//  年付 ÷ 12、季付 ÷ 3、周付 × 4.345、每 N 天 × (30.4 ÷ N)。
//

import Foundation

/// 订阅总览计算器。
enum SubscriptionOverview {

    /// 未来扣费时间轴的一项。
    struct DueItem: Hashable, Sendable {
        let subscriptionID: UUID
        let name: String
        /// 应扣日。
        let day: DateOnly
        let amount: Money

        /// 是否已经过期未处理（用于时间轴打标）。
        func isOverdue(on today: DateOnly) -> Bool { day < today }
    }

    // MARK: - 折算常数（PRD 4.4）

    /// 一年按 365 天算，一周按 7 天算（与 `4.345 周/月` 同源：365 ÷ 12 ÷ 7 = 4.3452…）
    private static let daysPerYear: Int64 = 365
    private static let daysPerWeek: Int64 = 7
    /// 周付折算到每月：4.345 周（PRD 4.4 原文）
    private static let weeksPerMonthThousandths: Int64 = 4345
    /// 日付折算到每月：30.4 天（PRD 4.4 原文）
    private static let daysPerMonthThousandths: Int64 = 30_400
    /// 千分位放大倍数
    private static let thousand: Int64 = 1_000

    // MARK: - 每月固定支出

    /// 每月固定支出（只统计 `active` 订阅）。
    ///
    /// 计算顺序：**先求和（千分位精度）→ 再取整到分 → 最后取整到元**。
    /// 反过来"每条先取整再求和"会让 12 条 ¥0.4 的订阅变成 ¥0 而不是 ¥5。
    ///
    /// - Parameter snapshots: 订阅快照（非 active 会被忽略）。
    /// - Returns: 取整到元的每月固定支出（UI 需标注"约"）。
    static func monthlyFixedCost(_ snapshots: [SubscriptionSnapshot]) -> Money {
        var totalThousandths: Int64 = 0
        for snapshot in snapshots where snapshot.status == .active {
            totalThousandths = saturatingAdd(totalThousandths, monthlyThousandths(of: snapshot))
        }
        return roundedToYuan(fromThousandths: totalThousandths)
    }

    /// 单条订阅折算到"每月"的千分位分数（1/1000 分）。
    ///
    /// 折算公式（PRD 4.4）：
    /// | 周期 | 每月 = | 千分位实现 |
    /// | --- | --- | --- |
    /// | 每 N 月 | 金额 ÷ N | `amount × 1000 ÷ N` |
    /// | 每 N 季 | 金额 ÷ (3N) | `amount × 1000 ÷ (3N)` |
    /// | 每 N 年 | 金额 ÷ (12N) | `amount × 1000 ÷ (12N)` |
    /// | 每 N 周 | 金额 × 4.345 ÷ N | `amount × 4345 ÷ N` |
    /// | 每 N 天 | 金额 × 30.4 ÷ N | `amount × 30400 ÷ N` |
    static func monthlyThousandths(of snapshot: SubscriptionSnapshot) -> Int64 {
        let amount = max(snapshot.amount, 0)
        let value = Int64(max(snapshot.cycleValue, 1))

        switch snapshot.cycleUnit {
        case .month:
            return multiplyDivideThousandths(amount, thousand, value)
        case .quarter:
            return multiplyDivideThousandths(amount, thousand, 3 * value)
        case .year:
            return multiplyDivideThousandths(amount, thousand, 12 * value)
        case .week:
            return multiplyDivideThousandths(amount, weeksPerMonthThousandths, value)
        case .day:
            return multiplyDivideThousandths(amount, daysPerMonthThousandths, value)
        }
    }

    // MARK: - 年度总成本

    /// 年度订阅总成本 = Σ 一年内扣费次数 × 金额（PRD 4.4）。
    ///
    /// 与"每月固定支出 ×12"不同：这个数字是"真实会扣多少"，所以按**次数**算而不是按均值，
    /// 周付一年是 52 次而不是 4.345×12＝52.14 次。
    ///
    /// - Parameter snapshots: 订阅快照（只统计 active）。
    /// - Returns: 年度成本（精确到分）。
    static func yearlyCost(_ snapshots: [SubscriptionSnapshot]) -> Money {
        var totalCents: Int64 = 0
        for snapshot in snapshots where snapshot.status == .active {
            totalCents = saturatingAdd(totalCents, yearlyCents(of: snapshot))
        }
        return Money(cents: totalCents)
    }

    /// 单条订阅的年度扣费金额（分）。
    static func yearlyCents(of snapshot: SubscriptionSnapshot) -> Int64 {
        let amount = max(snapshot.amount, 0)
        let value = Int64(max(snapshot.cycleValue, 1))

        switch snapshot.cycleUnit {
        case .day:
            // 365 天 ÷ (N 天) 次
            return multiplyDivideRounded(amount, daysPerYear, value)
        case .week:
            // 365 天 ÷ (7N 天) 次
            return multiplyDivideRounded(amount, daysPerYear, daysPerWeek * value)
        case .month:
            // 12 ÷ N 次
            return multiplyDivideRounded(amount, 12, value)
        case .quarter:
            // 4 ÷ N 次
            return multiplyDivideRounded(amount, 4, value)
        case .year:
            // 1 ÷ N 次（N 年一次；N>1 时不足一次的按比例算）
            return multiplyDivideRounded(amount, 1, value)
        }
    }

    // MARK: - 未来扣费时间轴

    /// 未来 `days` 天内的扣费项，按日期升序。
    ///
    /// 包含**已过期但还没被扫描处理**的下一期（`day < today`）：对用户来说它仍然是"接下来要扣的钱"，
    /// 藏起来只会让人以为没有这笔支出。UI 可以用 `DueItem.isOverdue(on:)` 打标。
    ///
    /// - Parameters:
    ///   - snapshots: 订阅快照（只统计 active）。
    ///   - today: 今天。
    ///   - days: 时间窗（默认 30 天）。
    ///   - itemLimit: 最多返回多少项（防御：每天扣费的订阅在 30 天窗口里会有 30 项，仍可控）。
    /// - Returns: 按日期升序的时间轴。
    static func upcoming(
        _ snapshots: [SubscriptionSnapshot],
        today: DateOnly,
        within days: Int = 30,
        itemLimit: Int = 200
    ) -> [DueItem] {
        guard today.key > 0 else { return [] }
        let horizon = today.adding(days: max(days, 0))
        var items: [DueItem] = []

        for snapshot in snapshots where snapshot.status == .active {
            guard let start = snapshot.nextBillingDate else { continue }
            var cursor = start
            var steps = 0

            while cursor.key > 0, cursor <= horizon, items.count < itemLimit, steps < itemLimit {
                items.append(
                    DueItem(
                        subscriptionID: snapshot.id,
                        name: snapshot.name,
                        day: cursor,
                        amount: Money(cents: max(snapshot.amount, 0))
                    )
                )
                let next = snapshot.advanced(from: cursor)
                guard next.key > cursor.key else { break }
                cursor = next
                steps += 1
            }
        }

        // 同一天多个订阅：先按日期，再按名称，保证顺序稳定（列表不能每次刷新都换位置）
        return items.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.subscriptionID.uuidString < $1.subscriptionID.uuidString
        }
    }

    /// 时间轴合计金额。
    static func upcomingTotal(_ items: [DueItem]) -> Money {
        items.reduce(Money.zero) { $0 + $1.amount }
    }

    // MARK: - 整数运算工具

    /// `a × b ÷ c`，用千分位放大避免浮点。溢出时饱和到 `Int64.max`。
    private static func multiplyDivideThousandths(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64 {
        guard c != 0 else { return 0 }
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { return a >= 0 ? Int64.max : Int64.min }
        return product / c
    }

    /// `a × b ÷ c`，结果四舍五入到整数。溢出时饱和。
    private static func multiplyDivideRounded(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64 {
        guard c != 0 else { return 0 }
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        if overflow { return a >= 0 ? Int64.max : Int64.min }
        let (quotient, remainder) = product.quotientAndRemainder(dividingBy: c)
        // 余数超过一半则进位（金额恒为非负，因此不必处理负向舍入）
        let absRemainder = remainder < 0 ? -remainder : remainder
        let absDivisor = c < 0 ? -c : c
        let shouldRoundUp = absRemainder * 2 >= absDivisor
        guard shouldRoundUp else { return quotient }
        return quotient + (product >= 0 ? 1 : -1)
    }

    /// 千分位分 → 取整到元的金额。
    ///
    /// 两步取整（先到分，再到元）是为了让"12 条 ¥0.4 的订阅"算出 ¥5 而不是 ¥0。
    private static func roundedToYuan(fromThousandths thousandths: Int64) -> Money {
        let cents = multiplyDivideRounded(thousandths, 1, thousand)
        let (wholeYuan, remainder) = cents.quotientAndRemainder(dividingBy: 100)
        // 到元再四舍五入一次（¥4.60 显示 ¥5，¥4.40 显示 ¥4）
        return Money(cents: (remainder >= 50 ? wholeYuan + 1 : wholeYuan) * 100)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs >= 0 ? Int64.max : Int64.min) : sum
    }
}
