//
//  ThemeTests.swift
//  一账Tests / DesignSystem
//
//  为什么设计系统要写测试：T02 的验收标准里有两条是**可量化的**——
//  ① "12 色 + 40 图标 + 19 分类 + 5 账户齐全" → 计数断言；
//  ② "深色下分类色对比度 ≥3:1" → WCAG 对比度公式断言。
//  第二条如果不写成测试，就只能靠肉眼在深色模拟器里"看着还行"，而这正是最容易漏的地方。
//

import XCTest
import SwiftUI
@testable import YiZhang

final class ThemeTests: XCTestCase {

    /// 深色模式页面背景（iOS `systemGroupedBackground` 的深色值）。
    private let darkBackground = "#1C1C1E"
    private let lightBackground = "#FFFFFF"
    /// 最低对比度要求（T02 验收：≥3:1）
    private let minimumContrast = 3.0

    // MARK: - 色板

    func testPaletteHasTwelveColors() {
        XCTAssertEqual(Theme.brandColors.count, 12)
        XCTAssertEqual(Set(Theme.brandColors.map(\.key)).count, 12, "色板 key 不可重复")
        XCTAssertEqual(Set(Theme.brandColors.map(\.lightHex)).count, 12, "浅色 hex 不可重复")
    }

    func testEveryLightColorMeetsContrastOnWhite() {
        for color in Theme.brandColors {
            let ratio = Theme.contrastRatio(color.lightHex, lightBackground)
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimumContrast,
                "\(color.displayName) 浅色 \(color.lightHex) 在浅色背景上对比度只有 \(String(format: "%.2f", ratio))"
            )
        }
    }

    func testEveryDarkColorMeetsContrastOnDarkBackground() {
        for color in Theme.brandColors {
            let ratio = Theme.contrastRatio(color.darkHex, darkBackground)
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimumContrast,
                "\(color.displayName) 深色 \(color.darkHex) 在深色背景上对比度只有 \(String(format: "%.2f", ratio))"
            )
        }
    }

    func testDarkVariantLookup() {
        let foodLight = PresetCatalog.expenseCategories[0].colorHex
        XCTAssertNotEqual(Theme.darkHex(for: foodLight), foodLight, "已知色板色应能查到深色变体")
        XCTAssertEqual(Theme.darkHex(for: "#123456"), "#123456", "未知颜色不做魔法变换")
    }

    func testContrastRatioSanity() {
        XCTAssertEqual(Theme.contrastRatio("#000000", "#FFFFFF"), 21, accuracy: 0.01)
        XCTAssertEqual(Theme.contrastRatio("#FFFFFF", "#FFFFFF"), 1, accuracy: 0.01)
        // 非法 hex 退化为 0 亮度（测试能因此拦住脏数据）
        XCTAssertEqual(Theme.relativeLuminance(hex: "not-a-color"), 0)
    }

    func testHexParsingAcceptsBothPrefixedAndPlain() {
        XCTAssertNotNil(Theme.rgbComponents(hex: "#C0392B"))
        XCTAssertNotNil(Theme.rgbComponents(hex: "C0392B"))
        XCTAssertNil(Theme.rgbComponents(hex: "#C03"))
    }

    // MARK: - 预置目录完整性

    func testPresetCatalogCounts() {
        XCTAssertEqual(PresetCatalog.expenseCategories.count, 14)
        XCTAssertEqual(PresetCatalog.incomeCategories.count, 5)
        XCTAssertEqual(PresetCatalog.allCategories.count, 19)
        XCTAssertEqual(PresetCatalog.accounts.count, 5)
        XCTAssertEqual(PresetCatalog.symbolNames.count, 40)
    }

    func testPresetKeysAreUnique() {
        let keys = PresetCatalog.allCategories.map(\.presetKey) + PresetCatalog.accounts.map(\.presetKey)
        XCTAssertEqual(Set(keys).count, keys.count, "presetKey 必须唯一，否则种子判重会串")
    }

    func testPresetCategoryNamesMatchPRD() {
        XCTAssertEqual(PresetCatalog.expenseCategories.map(\.name), [
            "餐饮", "买菜生鲜", "交通出行", "购物", "居住",
            "通讯网络", "娱乐", "医疗健康", "教育学习", "人情往来",
            "旅行", "宠物", "订阅服务", "其他"
        ])
        XCTAssertEqual(PresetCatalog.incomeCategories.map(\.name), [
            "工资", "奖金", "兼职副业", "投资收益", "其他收入"
        ])
        XCTAssertEqual(PresetCatalog.accounts.map(\.name), ["现金", "微信", "支付宝", "储蓄卡", "信用卡"])
    }

    func testEveryPresetIconIsInWhitelist() {
        for preset in PresetCatalog.allCategories {
            XCTAssertTrue(
                PresetCatalog.symbolNames.contains(preset.iconName),
                "\(preset.name) 的图标 \(preset.iconName) 不在 40 个白名单内"
            )
        }
    }

    func testUnknownSymbolFallsBack() {
        XCTAssertEqual(PresetCatalog.sanitizedSymbolName(""), "ellipsis.circle")
        XCTAssertEqual(PresetCatalog.sanitizedSymbolName("   "), "ellipsis.circle")
        XCTAssertEqual(PresetCatalog.sanitizedSymbolName("no.such.symbol"), "ellipsis.circle")
        XCTAssertEqual(PresetCatalog.sanitizedSymbolName("cart"), "cart")
    }

    // MARK: - 紧凑金额

    func testCompactMoneyText() {
        XCTAssertEqual(MoneyText.compactString(Money(cents: 12_345_678)), "12.3万")
        XCTAssertEqual(MoneyText.compactString(Money(cents: 10_000_000)), "10万")
        XCTAssertEqual(MoneyText.compactString(Money(cents: 1_000_000_000_000)), "100亿")
        XCTAssertEqual(MoneyText.compactString(Money(cents: 123_400_000_000)), "12.3亿")
        // 低于 1 万走普通两位小数格式
        XCTAssertEqual(MoneyText.compactString(Money(cents: 99_999)), "¥999.99")
    }

    func testCompactMoneyTextHandlesNegativeAndSign() {
        XCTAssertEqual(MoneyText.compactString(Money(cents: -12_345_678), sign: "-"), "-12.3万")
        XCTAssertEqual(MoneyText.compactString(Money(cents: 0), showsSymbol: false), "0.00")
    }

    // MARK: - 间距令牌

    func testSpacingScaleIsMultiplesOfFour() {
        let values = [
            Theme.Spacing.xxs, Theme.Spacing.xs, Theme.Spacing.sm,
            Theme.Spacing.md, Theme.Spacing.lg, Theme.Spacing.xl
        ]
        XCTAssertEqual(values, [4, 8, 12, 16, 24, 32])
        XCTAssertTrue(values.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    }

    func testMinimumTapSizeFollowsHIG() {
        XCTAssertEqual(Theme.minimumTapSize, 44)
    }
}
