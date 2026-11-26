//
//  PeriodComparisonParityTests.swift
//  一账Tests / Domain
//
//  R6：`PeriodComparison` 的百分比格式化与首页「较上月」卡用的
//  `ExpenseComparison.percentText` 是**两份实现**（Domain 不能 import Features，
//  也不许为了这次任务去改已上线的 `ExpenseComparison`）。
//
//  两份实现唯一可接受的代价就是"可能分叉"，所以这里把两边**逐字锁在一起**：
//  同一批输入，输出必须一个字符都不差。谁改了格式（多一位小数、去掉封顶、
//  把 `%` 换成 `％`），这里立刻红。
//
//  除了格式化，`make(current:baseline:)` 的四条分支顺序也是复制来的
//  （先判基线 > 0，再判相等，最后算百分比）。顺序错了不会崩，只会让
//  "当期 0、基线 0" 显示成「新增」而不是「—」，所以连方向一起比。
//

import XCTest
@testable import YiZhang

final class PeriodComparisonParityTests: XCTestCase {

    // MARK: - ① 百分比格式化

    /// 覆盖任务书点名的 `0/1/9/10/123/1240/9989/9990/12345` 以及各自的负数。
    ///
    /// `9989 / 9990` 是封顶阈值两侧：前者是最后一个"正常输出"的输入，
    /// 后者是第一个必须变成 `999%+` 的输入。少了这一对，把 `<` 写成 `<=`
    /// 这种错（9989 也封顶）就抓不到。
    private let thousandthsSamples: [Int64] = [
        0, 1, 9, 10, 123, 1_240, 9_989, 9_990, 9_991, 12_345, 999_999,
        -1, -9, -10, -123, -1_240, -9_989, -9_990, -9_991, -12_345
    ]

    func testPercentTextMatchesExpenseComparisonVerbatim() {
        for thousandths in thousandthsSamples {
            XCTAssertEqual(
                PeriodComparison.percentText(thousandths),
                ExpenseComparison.percentText(thousandths),
                "千分位 \(thousandths) 的格式化结果两边必须逐字相同"
            )
        }
    }

    func testPercentTextKeepsExactlyOneDecimal() {
        XCTAssertEqual(PeriodComparison.percentText(0), "0.0%")
        XCTAssertEqual(PeriodComparison.percentText(1), "0.1%")
        XCTAssertEqual(PeriodComparison.percentText(9), "0.9%")
        XCTAssertEqual(PeriodComparison.percentText(10), "1.0%")
        XCTAssertEqual(PeriodComparison.percentText(123), "12.3%")
        XCTAssertEqual(PeriodComparison.percentText(1_240), "124.0%")
        // 1.249% 这种输入要**截断**成 124.9%，不是四舍五入成 125.0%：
        // 整数除法天然是截断，写成浮点加法会引入不可复现的 .9999999 尾数
        XCTAssertEqual(PeriodComparison.percentText(1_249), "124.9%")
    }

    func testCapBoundaryIsExactlyNineThousandNineHundredNinety() {
        XCTAssertEqual(PeriodComparison.percentText(9_989), "998.9%", "阈值下方必须是正常数字")
        XCTAssertEqual(PeriodComparison.percentText(9_990), "999%+", "≥9990 必须封顶，不能印出 999.0%")
        XCTAssertEqual(PeriodComparison.percentText(12_345), "999%+")
        XCTAssertEqual(PeriodComparison.percentText(999_999), "999%+")
        // 封顶对符号不敏感：先取绝对值再判阈值
        XCTAssertEqual(PeriodComparison.percentText(-9_990), "999%+")
        XCTAssertEqual(PeriodComparison.percentText(-9_989), "998.9%")
        // 同一阈值两边都要有：一边封一边不封，用户会在两个页面看到不同的数字
        XCTAssertEqual(ExpenseComparison.percentText(9_990), "999%+")
        XCTAssertEqual(ExpenseComparison.percentText(9_989), "998.9%")
    }

    // MARK: - ② 计算分支

    /// 当期 × 基线的全组合（7×7）。含 0 基线、两期相等、增长、下降四类。
    private let centsSamples: [Int64] = [0, 1, 25, 100, 2_500, 298_000, 1_000_000]

    func testMakeMatchesExpenseComparisonOnEveryPair() {
        for current in centsSamples {
            for baseline in centsSamples {
                let mine = PeriodComparison.make(
                    current: Money(cents: current),
                    baseline: Money(cents: baseline)
                )
                let theirs = ExpenseComparison.make(
                    current: Money(cents: current),
                    previous: Money(cents: baseline)
                )

                XCTAssertEqual(
                    directionToken(mine.direction),
                    directionToken(theirs.direction),
                    "当期 \(current) / 基线 \(baseline) 的方向判定不一致（分支顺序被改过？）"
                )
                XCTAssertEqual(
                    mine.magnitudeThousandths,
                    theirs.magnitudeThousandths,
                    "当期 \(current) / 基线 \(baseline) 的百分比不一致"
                )
                // `isAvailable` 必须与 `ExpenseComparison` 的 `.unavailable` 严格互为逆
                XCTAssertEqual(
                    mine.isAvailable,
                    theirs.direction != .unavailable,
                    "当期 \(current) / 基线 \(baseline) 的「能否比较」判定不一致"
                )
            }
        }
    }

    func testBothPeriodsEmptyIsFlatNotUnavailable() {
        // 这条是"分支顺序"最容易踩的坑：先判相等再判基线 > 0，
        // 就会把"两期都空"判成 `.unavailable` → 卡片显示「新增」，凭空造出一笔新支出
        let comparison = PeriodComparison.make(current: .zero, baseline: .zero)
        XCTAssertEqual(comparison.direction, .flat)
        XCTAssertTrue(comparison.isAvailable)
        XCTAssertEqual(PeriodComparison.percentText(comparison.magnitudeThousandths), "0.0%")
    }

    func testBaselineOnlyEmptyMakesComparisonUnavailable() {
        let comparison = PeriodComparison.make(current: Money(cents: 1_200), baseline: .zero)
        XCTAssertEqual(comparison.direction, .unavailable)
        XCTAssertFalse(comparison.isAvailable, "基线为 0 时百分比无意义，不能拿 0 当占位")
        XCTAssertEqual(comparison.current.cents, 1_200)
    }

    func testNegativeBaselineIsTreatedAsUnavailable() {
        // 统计学上金额不该为负（A1 + `isCountable` 只收正数），但值类型必须全定义：
        // 负数基线不能参与除法（会算出"下跌 -300%"这种反号结论）
        let comparison = PeriodComparison.make(current: Money(cents: 100), baseline: Money(cents: -100))
        XCTAssertEqual(comparison.direction, .unavailable)
        XCTAssertEqual(ExpenseComparison.make(current: Money(cents: 100), previous: Money(cents: -100)).direction, .unavailable)
    }

    func testEqualPeriodsAreFlatWithZeroMagnitude() {
        let comparison = PeriodComparison.make(current: Money(cents: 2_500), baseline: Money(cents: 2_500))
        XCTAssertEqual(comparison.direction, .flat)
        XCTAssertEqual(comparison.magnitudeThousandths, 0, "持平时不要给 ▲0.0%")
    }

    // MARK: - ③ 默认值与容器

    func testEmptyComparisonIsFlatAndAvailable() {
        XCTAssertEqual(PeriodComparison.empty.direction, .flat)
        XCTAssertEqual(PeriodComparison.empty.current.cents, 0)
        XCTAssertEqual(PeriodComparison.empty.baseline.cents, 0)
    }

    func testStatisticsComparisonCurrentAlwaysComesFromYearOverYear() {
        // 同比与环比共用同一个当期。卡片的主数字取 `current`，
        // 如果将来有人只改了 `yoy` 或只改了 `mom` 的 current，主数字与 chip 会对不上，
        // 而这种不一致在 UI 上极难发现 —— 所以 `current` 只有一个来源。
        let yoy = PeriodComparison.make(current: Money(cents: 3_482), baseline: Money(cents: 2_980))
        let mom = PeriodComparison.make(current: Money(cents: 9_999), baseline: Money(cents: 3_120))
        let pair = StatisticsComparison(yoy: yoy, mom: mom)
        XCTAssertEqual(pair.current.cents, 3_482, "主数字必须取同比那一份当期，不能取环比")

        // 元组构造器只是省字段名，行为必须与逐字段构造完全一致
        let fromTuple = StatisticsComparison((yoy: yoy, mom: mom))
        XCTAssertEqual(fromTuple, pair)
        XCTAssertEqual(fromTuple.current.cents, pair.current.cents)
    }

    func testEmptyStatisticsComparisonHasNoMonthOverMonth() {
        XCTAssertNil(StatisticsComparison.empty.mom, "本年档没有环比，`.empty` 也不该造一个出来")
        XCTAssertEqual(StatisticsComparison.empty.current.cents, 0)
    }

    // MARK: - 夹具

    private func directionToken(_ direction: PeriodComparison.Direction) -> String {
        switch direction {
        case .increase: return "increase"
        case .decrease: return "decrease"
        case .flat: return "flat"
        case .unavailable: return "unavailable"
        }
    }

    private func directionToken(_ direction: ExpenseComparison.Direction) -> String {
        switch direction {
        case .increase: return "increase"
        case .decrease: return "decrease"
        case .flat: return "flat"
        case .unavailable: return "unavailable"
        }
    }
}
