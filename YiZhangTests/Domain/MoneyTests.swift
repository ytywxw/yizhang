//
//  MoneyTests.swift
//  一账Tests / Domain
//
//  Money 是金额的唯一入口（A1），所以这里的行为必须是"逐条可验证"的：
//  解析成功/失败、格式化、比较、溢出。
//

import XCTest
@testable import YiZhang

final class MoneyTests: XCTestCase {

    // MARK: - 解析成功

    func testParseWholeNumber() {
        XCTAssertEqual(Money.parse("12")?.cents, 1200)
    }

    func testParseOneDecimal() {
        // "12.5" 的 5 是 5 角 = 50 分
        XCTAssertEqual(Money.parse("12.5")?.cents, 1250)
    }

    func testParseTwoDecimals() {
        XCTAssertEqual(Money.parse("12.50")?.cents, 1250)
        XCTAssertEqual(Money.parse("12.05")?.cents, 1205)
    }

    func testParseLeadingDot() {
        XCTAssertEqual(Money.parse(".5")?.cents, 50)
        XCTAssertEqual(Money.parse(".05")?.cents, 5)
    }

    func testParseZeroPaddedFraction() {
        XCTAssertEqual(Money.parse("0.05")?.cents, 5)
    }

    func testParseZero() {
        XCTAssertEqual(Money.parse("0"), Money.zero)
        XCTAssertEqual(Money.parse("0.00"), Money.zero)
    }

    func testParseToleratesCurrencySymbolAndPlusSign() {
        XCTAssertEqual(Money.parse("¥12.50")?.cents, 1250)
        XCTAssertEqual(Money.parse("￥12.50")?.cents, 1250)
        XCTAssertEqual(Money.parse("+12.50")?.cents, 1250)
        XCTAssertEqual(Money.parse(" 12.50 ")?.cents, 1250)
    }

    func testParseToleratesGroupingSeparator() {
        XCTAssertEqual(Money.parse("1,234.50")?.cents, 123_450)
        XCTAssertEqual(Money.parse("1,234,567")?.cents, 123_456_700)
    }

    // MARK: - 解析失败

    func testParseRejectsEmptyInput() {
        XCTAssertNil(Money.parse(""))
        XCTAssertNil(Money.parse("   "))
        XCTAssertNil(Money.parse("."))
        XCTAssertNil(Money.parse("¥"))
    }

    func testParseRejectsNegative() {
        XCTAssertNil(Money.parse("-5"))
        XCTAssertNil(Money.parse("-0.01"))
    }

    func testParseRejectsMultipleDots() {
        XCTAssertNil(Money.parse("1.2.3"))
    }

    func testParseRejectsMoreThanTwoDecimals() {
        // 不做四舍五入：多出的位数无法用"分"精确表示，宁可拒绝
        XCTAssertNil(Money.parse("1.234"))
        XCTAssertNil(Money.parse("0.001"))
    }

    func testParseRejectsNonNumeric() {
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse("12a"))
        XCTAssertNil(Money.parse("1 2"))
        XCTAssertNil(Money.parse("１２"))
    }

    func testParseRejectsMalformedGrouping() {
        XCTAssertNil(Money.parse("1,2,3"))
        XCTAssertNil(Money.parse("1,23"))
        XCTAssertNil(Money.parse(",123"))
        XCTAssertNil(Money.parse("12,"))
    }

    // MARK: - 溢出保护

    func testParseAcceptsInt64Maximum() {
        // Int64.max = 9223372036854775807 分 = 92233720368547758.07 元
        XCTAssertEqual(Money.parse("92233720368547758.07")?.cents, Int64.max)
    }

    func testParseRejectsOverflow() {
        XCTAssertNil(Money.parse("92233720368547758.08"))
        XCTAssertNil(Money.parse("99999999999999999999"))
    }

    func testExactArithmeticReturnsNilOnOverflow() {
        XCTAssertNil(Money(cents: Int64.max).adding(Money(cents: 1)))
        XCTAssertNil(Money(cents: Int64.min).subtracting(Money(cents: 1)))
        XCTAssertNil(Money(cents: Int64.min).negated())
        XCTAssertEqual(Money(cents: 100).adding(Money(cents: 25))?.cents, 125)
        XCTAssertEqual(Money(cents: 100).subtracting(Money(cents: 25))?.cents, 75)
    }

    func testSaturatingOperatorsDoNotCrash() {
        XCTAssertEqual((Money(cents: Int64.max) + Money(cents: 1)).cents, Int64.max)
        XCTAssertEqual((Money(cents: Int64.min) - Money(cents: 1)).cents, Int64.min)
        XCTAssertEqual((Money(cents: Int64.min) + Money(cents: -1)).cents, Int64.min)
        XCTAssertEqual((-Money(cents: Int64.min)).cents, Int64.min)
    }

    // MARK: - 展示

    func testYuanString() {
        XCTAssertEqual(Money(cents: 1250).yuanString, "12.50")
        XCTAssertEqual(Money(cents: 1200).yuanString, "12.00")
        XCTAssertEqual(Money(cents: 5).yuanString, "0.05")
        XCTAssertEqual(Money(cents: 0).yuanString, "0.00")
        XCTAssertEqual(Money(cents: -1250).yuanString, "-12.50")
        XCTAssertEqual(Money(cents: Int64.min).yuanString, "-92233720368547758.08")
    }

    func testFormattedUsesCurrencySymbol() {
        XCTAssertEqual(Money(cents: 1250).formatted(), "¥12.50")
        XCTAssertEqual(Money(cents: 5).formatted(), "¥0.05")
        XCTAssertEqual(Money(cents: -1250).formatted(), "-¥12.50")
    }

    func testFormattedStyles() {
        XCTAssertEqual(Money(cents: 1250).formatted(style: .signed), "+¥12.50")
        XCTAssertEqual(Money(cents: -1250).formatted(style: .signed), "-¥12.50")
        XCTAssertEqual(Money(cents: 0).formatted(style: .signed), "¥0.00")
        XCTAssertEqual(Money(cents: 1250).formatted(style: .noSymbol), "12.50")
    }

    func testAccessibilityText() {
        XCTAssertEqual(Money(cents: 1250).accessibilityText, "12元5角")
        XCTAssertEqual(Money(cents: 1200).accessibilityText, "12元")
        XCTAssertEqual(Money(cents: 5).accessibilityText, "5分")
        XCTAssertEqual(Money(cents: 0).accessibilityText, "0元")
        XCTAssertEqual(Money(cents: -1250).accessibilityText, "负12元5角")
    }

    // MARK: - 比较与相等

    func testComparableAndEquality() {
        let amounts = [Money(cents: 300), Money(cents: -100), Money(cents: 1200)]
        XCTAssertEqual(amounts.sorted().map(\.cents), [-100, 300, 1200])
        XCTAssertTrue(Money(cents: 100) < Money(cents: 101))
        XCTAssertFalse(Money(cents: 100) < Money(cents: 100))
        XCTAssertEqual(Money(cents: 100), Money(cents: 100))
        XCTAssertEqual(Set([Money(cents: 1), Money(cents: 1)]).count, 1)
    }

    func testCodableRoundTripKeepsCents() throws {
        let original = Money(cents: 123_456)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Money.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
