//
//  CycleAdvancerTests.swift
//  一账Tests / Domain
//
//  覆盖架构 §5.2 的 20 条期末对齐用例（R-SUB-8），全部是纯函数、零 IO。
//  最关键的是用例 4/5：**下下次仍从锚定日推算，不从被夹紧后的日期继续推**，
//  这是"1/31 → 2/28 → 3/28 永久漂移"这个高风险缺陷（R4）的唯一防线。
//

import XCTest
@testable import YiZhang

final class CycleAdvancerTests: XCTestCase {

    /// 一条推进用例。
    private struct Case {
        let index: Int
        let start: Int32
        let anchorDay: Int
        let unit: CycleUnit
        let value: Int
        let expected: Int32
        let note: String
    }

    /// 架构 §5.2 的 20 条用例，逐条照抄。
    private let table: [Case] = [
        Case(index: 1, start: 20250131, anchorDay: 31, unit: .month, value: 1,
             expected: 20250228, note: "月末夹紧（平年）"),
        Case(index: 2, start: 20240131, anchorDay: 31, unit: .month, value: 1,
             expected: 20240229, note: "闰年 2 月"),
        Case(index: 3, start: 20240229, anchorDay: 29, unit: .month, value: 1,
             expected: 20240329, note: "闰日不漂"),
        Case(index: 4, start: 20250228, anchorDay: 31, unit: .month, value: 1,
             expected: 20250331, note: "下下次仍从基准推算"),
        Case(index: 5, start: 20250430, anchorDay: 31, unit: .month, value: 1,
             expected: 20250531, note: "连续 4 次不漂移（链末）"),
        Case(index: 6, start: 20250130, anchorDay: 30, unit: .month, value: 1,
             expected: 20250228, note: "锚定 30 遇 2 月"),
        Case(index: 7, start: 20250331, anchorDay: 31, unit: .month, value: 1,
             expected: 20250430, note: "30 天月夹紧"),
        Case(index: 8, start: 20250131, anchorDay: 31, unit: .month, value: 2,
             expected: 20250331, note: "每 2 个月"),
        Case(index: 9, start: 20250331, anchorDay: 31, unit: .month, value: 2,
             expected: 20250531, note: "每 2 个月连续"),
        Case(index: 10, start: 20250531, anchorDay: 31, unit: .month, value: 2,
             expected: 20250731, note: "跳过 6 月（30 天）不影响"),
        Case(index: 11, start: 20250131, anchorDay: 31, unit: .quarter, value: 1,
             expected: 20250430, note: "季度 + 夹紧"),
        Case(index: 12, start: 20251130, anchorDay: 30, unit: .quarter, value: 1,
             expected: 20260228, note: "季度跨年 + 2 月"),
        Case(index: 13, start: 20250228, anchorDay: 28, unit: .year, value: 1,
             expected: 20260228, note: "年付"),
        Case(index: 14, start: 20240229, anchorDay: 29, unit: .year, value: 1,
             expected: 20250228, note: "闰日年付夹紧"),
        Case(index: 15, start: 20250228, anchorDay: 29, unit: .year, value: 1,
             expected: 20260228, note: "闰日不复活（已知有损，风险 R4）"),
        Case(index: 16, start: 20250131, anchorDay: 31, unit: .day, value: 45,
             expected: 20250317, note: "每 45 天，跨月不夹紧"),
        Case(index: 17, start: 20250101, anchorDay: 1, unit: .week, value: 2,
             expected: 20250115, note: "每两周"),
        Case(index: 18, start: 20251215, anchorDay: 15, unit: .month, value: 1,
             expected: 20260115, note: "跨年"),
        Case(index: 19, start: 20251231, anchorDay: 31, unit: .month, value: 1,
             expected: 20260131, note: "跨年 + 锚定 31"),
        Case(index: 20, start: 20250131, anchorDay: 1, unit: .month, value: 1,
             expected: 20250201, note: "手改后锚定日重置生效")
    ]

    // MARK: - 20 条用例（表驱动 + 单独断言，失败时能直接看出是第几条）

    func testAllTwentySpecCases() {
        XCTAssertEqual(table.count, 20)

        for testCase in table {
            let result = CycleAdvancer.advance(
                from: DateOnly(key: testCase.start),
                unit: testCase.unit,
                value: testCase.value,
                anchorDay: testCase.anchorDay
            )
            XCTAssertEqual(
                result.key,
                testCase.expected,
                "用例 \(testCase.index) 失败（\(testCase.note)）：\(testCase.start) anchor=\(testCase.anchorDay) "
                    + "\(testCase.unit.raw)×\(testCase.value) 期望 \(testCase.expected)，实际 \(result.key)"
            )
        }
    }

    // MARK: - 逐条单独用例（可读性更好的失败定位）

    func testCase01MonthEndClampedInCommonYear() {
        XCTAssertEqual(advance(20250131, .month, 1, anchor: 31), 20250228)
    }

    func testCase02LeapYearFebruary() {
        XCTAssertEqual(advance(20240131, .month, 1, anchor: 31), 20240229)
    }

    func testCase03LeapDayDoesNotDrift() {
        XCTAssertEqual(advance(20240229, .month, 1, anchor: 29), 20240329)
    }

    func testCase04AnchorDaySurvivesClamping() {
        // 2/28 不是锚定日，锚定日 31 才是；推进结果必须是 3/31 而不是 3/28
        XCTAssertEqual(advance(20250228, .month, 1, anchor: 31), 20250331)
    }

    func testCase05FourConsecutiveStepsDoNotDrift() {
        // 1/31 → 2/28 → 3/31 → 4/30 → 5/31：每一步都从锚定日 31 推算
        var cursor = DateOnly(key: 20250131)
        var visited: [Int32] = [cursor.key]
        for _ in 0..<4 {
            cursor = CycleAdvancer.advance(from: cursor, unit: .month, value: 1, anchorDay: 31)
            visited.append(cursor.key)
        }
        XCTAssertEqual(visited, [20250131, 20250228, 20250331, 20250430, 20250531])
    }

    func testCase06AnchorThirtyMeetsFebruary() {
        XCTAssertEqual(advance(20250130, .month, 1, anchor: 30), 20250228)
    }

    func testCase07ThirtyDayMonthClamps() {
        XCTAssertEqual(advance(20250331, .month, 1, anchor: 31), 20250430)
    }

    func testCase08EveryTwoMonths() {
        XCTAssertEqual(advance(20250131, .month, 2, anchor: 31), 20250331)
    }

    func testCase09EveryTwoMonthsConsecutive() {
        XCTAssertEqual(advance(20250331, .month, 2, anchor: 31), 20250531)
    }

    func testCase10SkippingShortMonthDoesNotMatter() {
        XCTAssertEqual(advance(20250531, .month, 2, anchor: 31), 20250731)
    }

    func testCase11QuarterlyClamped() {
        XCTAssertEqual(advance(20250131, .quarter, 1, anchor: 31), 20250430)
    }

    func testCase12QuarterlyAcrossYearIntoFebruary() {
        XCTAssertEqual(advance(20251130, .quarter, 1, anchor: 30), 20260228)
    }

    func testCase13Yearly() {
        XCTAssertEqual(advance(20250228, .year, 1, anchor: 28), 20260228)
    }

    func testCase14LeapDayYearlyClamped() {
        XCTAssertEqual(advance(20240229, .year, 1, anchor: 29), 20250228)
    }

    func testCase15LeapDayYearlyDoesNotRevive() {
        // 已知有损场景：2/29 年付在平年夹紧到 2/28 后，闰年也不会回到 2/29（风险 R4）
        XCTAssertEqual(advance(20250228, .year, 1, anchor: 29), 20260228)
    }

    func testCase16EveryFortyFiveDays() {
        XCTAssertEqual(advance(20250131, .day, 45, anchor: 31), 20250317)
    }

    func testCase17EveryTwoWeeks() {
        XCTAssertEqual(advance(20250101, .week, 2, anchor: 1), 20250115)
    }

    func testCase18MonthlyAcrossYear() {
        XCTAssertEqual(advance(20251215, .month, 1, anchor: 15), 20260115)
    }

    func testCase19MonthlyAcrossYearWithAnchorThirtyOne() {
        XCTAssertEqual(advance(20251231, .month, 1, anchor: 31), 20260131)
    }

    func testCase20AnchorResetAfterManualChange() {
        // 用户手改下次扣费日为 1 号后，锚定日随之变成 1
        XCTAssertEqual(advance(20250131, .month, 1, anchor: 1), 20250201)
    }

    // MARK: - 无锚定日的自然推进

    func testNaturalAdvanceUsesOwnDayAsAnchor() {
        XCTAssertEqual(CycleAdvancer.advance(from: DateOnly(key: 20250131), unit: .month, value: 1).key, 20250228)
        XCTAssertEqual(CycleAdvancer.advance(from: DateOnly(key: 20250228), unit: .month, value: 1).key, 20250328)
    }

    func testReversedArgumentOrderOverloadMatchesCoreApi() {
        let viaNamedOrder = CycleAdvancer.advance(
            from: DateOnly(key: 20250228), anchorDay: 31, unit: .month, value: 1
        )
        XCTAssertEqual(viaNamedOrder.key, 20250331)
    }

    func testNonPositiveValueIsClampedToOneToKeepProgressMonotonic() {
        let start = DateOnly(key: 20250131)
        // value ≤ 0 按 1 处理：保证推进单调递增，绝不让补漏循环原地打转
        XCTAssertEqual(CycleAdvancer.advance(from: start, unit: .month, value: 0, anchorDay: 31).key, 20250228)
        XCTAssertEqual(CycleAdvancer.advance(from: start, unit: .day, value: -5).key, 20250201)
        XCTAssertGreaterThan(CycleAdvancer.advance(from: start, unit: .month, value: 0, anchorDay: 31), start)
    }

    func testZeroDateIsReturnedUnchanged() {
        XCTAssertEqual(CycleAdvancer.advance(from: DateOnly.zero, unit: .month, value: 1, anchorDay: 1), .zero)
    }

    func testAdvanceToFutureSkipsAllPastCyclesWithoutDrift() {
        // 从 1/31 出发，今天 4/1：顺延到 4/30（严格晚于今天），锚定日 31 未漂移
        let result = CycleAdvancer.advanceToFuture(
            from: DateOnly(key: 20250131),
            today: DateOnly(key: 20250401),
            unit: .month,
            value: 1,
            anchorDay: 31
        )
        XCTAssertEqual(result.key, 20250430)
    }

    // MARK: - 辅助

    private func advance(_ start: Int32, _ unit: CycleUnit, _ value: Int, anchor: Int) -> Int32 {
        CycleAdvancer.advance(
            from: DateOnly(key: start),
            unit: unit,
            value: value,
            anchorDay: anchor
        ).key
    }
}
