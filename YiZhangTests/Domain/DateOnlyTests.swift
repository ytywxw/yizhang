//
//  DateOnlyTests.swift
//  一账Tests / Domain
//
//  DateOnly 是"自然日"的唯一表示（A2）。这里验证三件事：
//  ① 年月日分解与月份键；② 区间（月 / 周，含跨月）；③ 加减天数跨月跨年与比较。
//

import XCTest
@testable import YiZhang

final class DateOnlyTests: XCTestCase {

    // MARK: - 分解

    func testComponents() {
        let day = DateOnly(key: 20251120)
        XCTAssertEqual(day.year, 2025)
        XCTAssertEqual(day.month, 11)
        XCTAssertEqual(day.day, 20)
        XCTAssertTrue(day.isValid)
    }

    func testMonthKey() {
        XCTAssertEqual(DateOnly(key: 20251120).monthKey, 2025 * 100 + 11)
        XCTAssertEqual(DateOnly(key: 20260101).monthKey, 2026 * 100 + 1)
    }

    func testZeroSentinelIsNotValid() {
        XCTAssertEqual(DateOnly.zero.key, 0)
        XCTAssertFalse(DateOnly.zero.isValid)
        XCTAssertEqual(DateOnly.zero.year, 0)
    }

    func testFailableInitRejectsImpossibleDate() {
        XCTAssertNil(DateOnly(year: 2025, month: 2, day: 30))
        XCTAssertNil(DateOnly(year: 2025, month: 13, day: 1))
        XCTAssertNotNil(DateOnly(year: 2024, month: 2, day: 29))
        XCTAssertNil(DateOnly(year: 2025, month: 2, day: 29))
    }

    func testInitFromDateMatchesComponents() {
        // 12:00 的正午时刻转自然日不会因 DST 偏移（`.date` 取当天 12:00 就是为了这个）
        let date = DateOnly(key: 20251120).date
        XCTAssertEqual(DateOnly(date), DateOnly(key: 20251120))
    }

    // MARK: - 区间

    func testMonthRangeForThirtyDayMonth() {
        let range = DateOnly.monthRange(202511)
        XCTAssertEqual(range.lowerBound, 20251101)
        XCTAssertEqual(range.upperBound, 20251130)
    }

    func testMonthRangeForFebruary() {
        XCTAssertEqual(DateOnly.monthRange(202502).upperBound, 20250228)
        XCTAssertEqual(DateOnly.monthRange(202402).upperBound, 20240229)
        XCTAssertEqual(DateOnly.monthRange(200002).upperBound, 20000229)  // 400 年整除，是闰年
        XCTAssertEqual(DateOnly.monthRange(190002).upperBound, 19000228)  // 100 年整除但非 400，不是闰年
    }

    func testWeekRangeMondayToSunday() {
        // 2025-11-20 是周四 → 本周一 11/17，本周日 11/23
        let range = DateOnly.weekRange(containing: DateOnly(key: 20251120))
        XCTAssertEqual(range.lowerBound, 20251117)
        XCTAssertEqual(range.upperBound, 20251123)
    }

    func testWeekRangeCrossesMonthBoundary() {
        // 2025-11-01 是周六 → 本周一 10/27，本周日 11/02（跨月）
        let range = DateOnly.weekRange(containing: DateOnly(key: 20251101))
        XCTAssertEqual(range.lowerBound, 20251027)
        XCTAssertEqual(range.upperBound, 20251102)
    }

    func testWeekRangeCrossesYearBoundary() {
        // 2025-12-31 是周三 → 本周一 2025-12-29，本周日 2026-01-04（跨年）
        let range = DateOnly.weekRange(containing: DateOnly(key: 20251231))
        XCTAssertEqual(range.lowerBound, 20251229)
        XCTAssertEqual(range.upperBound, 20260104)
    }

    func testWeekdayIndexAndName() {
        XCTAssertEqual(DateOnly(key: 20251117).weekdayIndexMondayFirst, 0)
        XCTAssertEqual(DateOnly(key: 20251117).weekdayName, "周一")
        XCTAssertEqual(DateOnly(key: 20251120).weekdayIndexMondayFirst, 3)
        XCTAssertEqual(DateOnly(key: 20251120).weekdayName, "周四")
        XCTAssertEqual(DateOnly(key: 20251123).weekdayIndexMondayFirst, 6)
        XCTAssertEqual(DateOnly(key: 20251123).weekdayName, "周日")
    }

    // MARK: - 加减

    func testAddingDaysWithinMonth() {
        XCTAssertEqual(DateOnly(key: 20251120).adding(days: 1).key, 20251121)
    }

    func testAddingDaysCrossesMonthAndYear() {
        XCTAssertEqual(DateOnly(key: 20250131).adding(days: 1).key, 20250201)
        XCTAssertEqual(DateOnly(key: 20251231).adding(days: 1).key, 20260101)
        XCTAssertEqual(DateOnly(key: 20250101).adding(days: -1).key, 20241231)
        XCTAssertEqual(DateOnly(key: 20240228).adding(days: 1).key, 20240229)
    }

    func testAddingMonthsClampsToMonthEnd() {
        // 自然推进（不保留锚定日）：1/31 + 1 月 → 2/28，再 +1 月 → 3/28。
        // 订阅场景必须用 CycleAdvancer 才不漂移。
        XCTAssertEqual(DateOnly(key: 20250131).adding(months: 1).key, 20250228)
        XCTAssertEqual(DateOnly(key: 20250228).adding(months: 1).key, 20250328)
    }

    func testAddingYearsClampsLeapDay() {
        XCTAssertEqual(DateOnly(key: 20240229).adding(years: 1).key, 20250228)
        XCTAssertEqual(DateOnly(key: 20240229).adding(years: 4).key, 20280229)
    }

    func testAdvancingMonthsKeepsAnchorDay() {
        // 同一天用锚定日推进两次，结果一致（不因中间被夹紧而漂移）
        let base = DateOnly(key: 20250131)
        let once = DateOnly.advancingMonths(from: base, months: 1, anchorDay: 31)
        let twice = DateOnly.advancingMonths(from: base, months: 2, anchorDay: 31)
        XCTAssertEqual(once.key, 20250228)
        XCTAssertEqual(twice.key, 20250331)
    }

    // MARK: - 比较与展示

    func testComparable() {
        let days = [DateOnly(key: 20251120), DateOnly(key: 20250101), DateOnly(key: 20251119)]
        XCTAssertEqual(days.sorted().map(\.key), [20250101, 20251119, 20251120])
        XCTAssertTrue(DateOnly(key: 20251119) < DateOnly(key: 20251120))
    }

    func testDisplayStrings() {
        let day = DateOnly(key: 20251120)
        XCTAssertEqual(day.displayString, "11月20日")
        XCTAssertEqual(day.fullDisplayString, "2025年11月20日")
        XCTAssertEqual(day.isoString, "2025-11-20")
        XCTAssertEqual(DateOnly(key: 20260105).isoString, "2026-01-05")
    }

    func testIsTodayUsesCurrentCalendar() {
        XCTAssertTrue(DateOnly(Date()).isToday)
        XCTAssertFalse(DateOnly(Date()).adding(days: 1).isToday)
    }

    func testCodableRoundTrip() throws {
        let original = DateOnly(key: 20251120)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DateOnly.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
