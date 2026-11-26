//
//  PeriodComparison.swift
//  一账 / Core / Domain
//
//  职责：统计页「同比 / 环比」与「账户支出构成」的值类型（V1.1 F-ACC-16）。
//
//  ## 为什么 `percentText` 是**复制**而不是复用 `ExpenseComparison`
//
//  `ExpenseComparison`（首页「较上月」卡）在 Features 层，且已经上线：
//  它的 `percentText` 有"≥999% 封顶成 `999%+`"这条被截图验收过的行为。
//  把两者合成一份有两种做法，都不合适：
//  ① 把 `ExpenseComparison` 搬进 Domain → 动的是首页已上线代码，本次任务书没有这项授权；
//  ② 让 Domain 反过来 import Features 层 → 分层倒挂。
//  所以这里是**有意**的两份实现 + 一条 parity 测试（`PeriodComparisonParityTests`）
//  把两边的输出逐字锁在一起：任何一边改了格式，测试立刻失败。
//
//  ## 为什么不把文案放进值类型
//
//  `ExpenseComparison.text` 的句式（「上月没有支出」「与上月持平」）是首页专用的。
//  统计页的句式随档位变：本月档说「去年同月无数据」，本年档要说「去年同期无数据」。
//  把句子塞进值类型就意味着值类型要知道"现在是哪一档"——那是视图的责任。
//  所以本文件只提供 **数值 + 方向 + 区间**，句子由 `ComparisonCopy`（Features 层）拼。
//

import Foundation

// MARK: - 一期与另一期的对比

/// 某一段时间的合计与另一段等长区间的对比。
///
/// 「同比」的基线是去年同形状的区间，「环比」的基线是上一个等长区间；
/// 两者用的是同一个值类型——因为差异只在"基线是哪个区间"，不在算法。
struct PeriodComparison: Hashable, Sendable {

    /// 变化方向。
    enum Direction: Hashable, Sendable {
        case increase
        case decrease
        case flat
        /// 基线为 0（或为负），百分比无意义。
        ///
        /// 这一档**不是错误**：新用户的上月/去年同月本来就没有账目。
        /// 用 `0` 当占位会让卡片显示「▲0.0%」，等于告诉用户"没变化"，那是错的。
        case unavailable
    }

    /// 当期合计。
    let current: Money
    /// 基线合计（去年同区间 / 上一个等长区间）。
    let baseline: Money
    let direction: Direction
    /// 百分比绝对值（千分位：`169` = 16.9%）。
    let magnitudeThousandths: Int64

    /// 无法计算时的安全值（当期与基线都为 0）。
    static let empty = PeriodComparison.make(current: .zero, baseline: .zero)

    /// 基线是否可与当期比较（为 0 时无从计算百分比）。
    var isAvailable: Bool { direction != .unavailable }

    /// 计算对比。
    ///
    /// 逐字对齐 `ExpenseComparison.make(current:previous:)` 的四条分支
    /// （基线 ≤ 0 / 相等 / 增长 / 下降），顺序也一样：
    /// 先判"基线是否 > 0"，再判"是否完全相等"，最后才算百分比。
    /// 调换前两条会让"当期 0、基线 0"落进 `.unavailable`，卡片就会显示「新增」——
    /// 而实际上两期都是空的，应该是「—」。
    ///
    /// - Parameters:
    ///   - current: 当期合计（分）。
    ///   - baseline: 基线合计（分）。
    static func make(current: Money, baseline: Money) -> PeriodComparison {
        guard baseline.cents > 0 else {
            // 基线为 0：当期有数 → 无法算百分比；当期也没有 → 持平（没有可比的东西）
            return PeriodComparison(
                current: current,
                baseline: baseline,
                direction: current.cents > 0 ? .unavailable : .flat,
                magnitudeThousandths: 0
            )
        }
        let deltaCents = current.cents - baseline.cents
        // 完全相等：明确"持平"，不要显示 ▲0.0%
        guard deltaCents != 0 else {
            return PeriodComparison(
                current: current,
                baseline: baseline,
                direction: .flat,
                magnitudeThousandths: 0
            )
        }
        let thousandths = deltaCents * 1_000 / baseline.cents
        return PeriodComparison(
            current: current,
            baseline: baseline,
            direction: deltaCents > 0 ? .increase : .decrease,
            magnitudeThousandths: abs(thousandths)
        )
    }

    /// 千分位 → 「16.9%」（纯整数运算，不经过 Double）。
    ///
    /// 超过 999% 直接封顶成「999%+」：基线只有 ¥25 而当期 ¥2,985 时真实增幅是 11,842%，
    /// 五位数字印在卡片上既占位又没有信息量（用户只需要知道"涨得非常多"）。
    ///
    /// **与 `ExpenseComparison.percentText` 逐字相同**，由 parity 测试锁定。
    static func percentText(_ thousandths: Int64) -> String {
        let value = abs(thousandths)
        guard value < 9_990 else { return "999%+" }
        return "\(value / 10).\(value % 10)%"
    }
}

// MARK: - 一组的对比结果

/// 同比 + 环比（本年档没有环比）。
struct StatisticsComparison: Hashable, Sendable {

    let yoy: PeriodComparison
    /// 环比；`nil` = 这一档不提供环比（本年档）。
    ///
    /// 为什么不给一个 `.flat` 占位：`nil` 让"这一档没有这个概念"与"有但相等"
    /// 在类型层面就分开，卡片不会凭空多出一行「环比 持平」。
    let mom: PeriodComparison?

    /// 加载中/出错时的安全值。
    static let empty = StatisticsComparison(yoy: .empty, mom: nil)

    /// 当期合计（同比与环比共用同一个当期，所以这里不必存两份）。
    ///
    /// 卡片的主数字取它，而不是各取 chip 自己的 `current`：一旦将来有人只改了一边，
    /// 主数字与 chip 里那句"当期多少"就会对不上，而这种不一致在 UI 上极难发现。
    var current: Money { yoy.current }

    /// 由计算器的元组结果构造。
    init(yoy: PeriodComparison, mom: PeriodComparison?) {
        self.yoy = yoy
        self.mom = mom
    }

    /// 由计算器的元组结果构造（免去调用点写两遍字段名）。
    init(_ pair: (yoy: PeriodComparison, mom: PeriodComparison?)) {
        self.init(yoy: pair.yoy, mom: pair.mom)
    }
}

// MARK: - 对比用到的三个区间

/// 对比卡的三个区间（都已经是 `yyyyMMdd` 整数键，闭区间）。
///
/// 为什么要把它暴露出来：卡片上必须写清"是和哪一段比"
/// （「2024 年 11 月 1–20 日」）。**只给金额不给区间**是"统计页和首页数字对不上"
/// 这类投诉的唯一来源——用户会默认同比是和"去年整月"比。
struct PeriodComparisonBounds: Hashable, Sendable {

    /// 当期区间。
    let current: ClosedRange<Int32>
    /// 同比基线区间。
    let yearOverYear: ClosedRange<Int32>
    /// 环比基线区间；`nil` = 这一档没有环比。
    let monthOverMonth: ClosedRange<Int32>?

    /// 加载中/出错时的安全值。
    static let empty = PeriodComparisonBounds(current: 0...0, yearOverYear: 0...0, monthOverMonth: nil)
}

// MARK: - 账户构成

/// 一个账户在某个范围里的支出（或收入）合计。
///
/// 与 `CategoryShare` 同构，只有 id 的语义不同：
/// - `accountID != nil`：一个真实账户；
/// - `accountID == nil && isMerged == false`：没有账户的账目（「未知账户」）；
/// - `accountID == nil && isMerged == true`：合并出来的「其他」。
///
/// 为什么不用 `UUID?` 直接当字典键：`[UUID?: Int64]` 的可选键在 Swift 里歧义太重
/// （`dict[nil]` 到底读的是"键为 nil"还是"没有这个键"？），
/// 计算器内部用哨兵 UUID，出口再翻译成 `nil`（与 `CategoryShare` 完全一致的做法）。
struct AccountShare: Identifiable, Hashable, Sendable {

    let accountID: UUID?
    let amount: Money
    /// 0…1
    let ratio: Double
    let isMerged: Bool

    var id: String {
        if let accountID { return accountID.uuidString }
        return isMerged ? "merged.other" : "unassignedAccount"
    }

    /// 百分比整数（四舍五入到整 %）。
    var percent: Int { Int((ratio * 100).rounded()) }
}
