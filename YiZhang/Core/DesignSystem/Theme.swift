//
//  Theme.swift
//  一账 / Core / DesignSystem
//
//  职责：视觉令牌的唯一来源——颜色（含深色双套）、字号层级、间距、圆角、阴影，以及对比度工具。
//
//  三条纪律：
//  ① **禁止业务判断**：本文件不知道"订阅""转账"是什么，只提供语义色与度量；
//  ② **颜色必须成对**：模型里只存一个 `colorHex`（浅色值），深色值由色板查表得到，
//     因此"分类色在深色模式下对比度 ≥3:1"是查表结果，不是每个视图各自调亮度；
//  ③ 对比度写成可执行函数（`contrastRatio`），而不是口头承诺——`ThemeTests` 会断言。
//

import SwiftUI
import UIKit

/// 视觉令牌集合。
enum Theme {

    // MARK: - 颜色

    /// 12 色品牌色板（与 `PresetCatalog` 同源，避免两处维护）。
    static var brandColors: [PresetCatalog.BrandColor] { PresetCatalog.brandColors }

    /// 给定浅色 hex，查色板得到深色 hex；查不到则原样返回（未知颜色不做魔法变换）。
    static func darkHex(for lightHex: String) -> String {
        let needle = lightHex.uppercased()
        return brandColors.first { $0.lightHex.uppercased() == needle }?.darkHex ?? lightHex
    }

    /// 自适应颜色：浅色模式用 `lightHex`，深色模式用 `darkHex`。
    static func adaptiveColor(lightHex: String, darkHex: String) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? darkHex : lightHex
            return UIColor(hexString: hex) ?? .systemGray
        })
    }

    /// 分类色（自动带深色变体）。
    static func categoryColor(hex: String) -> Color {
        adaptiveColor(lightHex: hex, darkHex: darkHex(for: hex))
    }

    /// 分类色的浅底（图标胶囊背景）：同色 15% 透明度，深浅两模式都成立。
    static func categoryTint(hex: String) -> Color {
        categoryColor(hex: hex).opacity(0.15)
    }

    /// 语境语义色。
    enum Semantic {
        /// 支出金额：主文本色（黑/白），不用红色——红只留给"逾期"和"删除"
        static let expense = Color.primary
        /// 收入金额：绿（浅 #2E7D32 / 深 #6ED47A，均 ≥4.5:1）
        static let income = adaptiveColor(lightHex: "#2E7D32", darkHex: "#6ED47A")
        /// 转账金额：灰
        static let transfer = Color.secondary
        /// 逾期 / 危险
        static let danger = adaptiveColor(lightHex: "#C0392B", darkHex: "#FF7B6B")
        /// 「待确认」徽标：琥珀色（V1.1 F-SUB-13）。
        ///
        /// 为什么不能用 `danger`：待确认只是"还没核对"，账目本身完全正常，
        /// 用红色会让用户以为这一笔出了问题（与「金额颜色只表类型」同一条纪律）。
        /// 也不能用 `.secondary`：那是"来源徽章"的颜色，两个灰度徽章并排等于都没有强调。
        /// 对比度：浅 #9A5B00 对白底 ≈5.2:1，深 #FFC44D 对 #1C1C1E ≈10.9:1，都过 4.5:1。
        static let pending = adaptiveColor(lightHex: "#9A5B00", darkHex: "#FFC44D")

        /// 卡片背景（深色模式下与页面背景形成层次）
        static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
        /// 页面背景
        static let pageBackground = Color(uiColor: .systemGroupedBackground)

        /// 账目类型 → 金额色。
        static func color(for type: EntryType) -> Color {
            switch type {
            case .expense: return expense
            case .income: return income
            case .transfer: return transfer
            }
        }
    }

    // MARK: - 字号层级

    /// 字号层级。金额用 40pt 大字（首页/输入页），并且一律等宽数字。
    ///
    /// ## 为什么要经过 `UIFontMetrics`
    ///
    /// 固定 pt（`Font.system(size: 40, ...)`）的字体**完全不跟随 Dynamic Type**：
    /// 用户在「设置 → 显示与亮度 → 文字大小」里把字号拉到 AX3，App 里一个字都不变大。
    /// 这对视力不好的用户等于功能缺失，也是 T24 的验收项。
    ///
    /// 这里用 `UIFontMetrics(forTextStyle:).scaledValue(for:)` 把**设计稿的 pt 当作基准值**：
    /// 默认字号下仍是 40 / 28 / 17 / 12（视觉与之前逐像素一致），
    /// 用户调大字号时按对应文本样式的曲线放大。
    ///
    /// 这些是**计算属性**而不是 `static let`：`UIFontMetrics` 读的是当前 trait collection，
    /// 必须在每次 body 求值时重新算，否者改完字号要重启 App 才生效。
    enum Typography {

        /// 基准 pt → 跟随 Dynamic Type 的 `Font`。
        ///
        /// - Parameters:
        ///   - size: 设计稿在**默认字号**下的 pt。
        ///   - weight: 字重。
        ///   - style: 按哪个文本样式的曲线缩放（不是按 size 反推，避免两头对不上）。
        ///   - monospaced: 金额一律等宽数字（数字跳动时不抖）。
        private static func scaled(
            _ size: CGFloat,
            weight: Font.Weight,
            style: UIFont.TextStyle,
            monospaced: Bool = false
        ) -> Font {
            let scaledSize = UIFontMetrics(forTextStyle: style).scaledValue(for: size)
            let font = Font.system(size: scaledSize, weight: weight)
            return monospaced ? font.monospacedDigit() : font
        }

        static var amount: Font {
            scaled(40, weight: .semibold, style: .largeTitle, monospaced: true)
        }

        static var amountMedium: Font {
            scaled(28, weight: .semibold, style: .title1, monospaced: true)
        }

        static var amountSmall: Font {
            scaled(17, weight: .medium, style: .body, monospaced: true)
        }

        static var title: Font {
            scaled(22, weight: .semibold, style: .title2)
        }

        static var headline: Font {
            scaled(17, weight: .semibold, style: .headline)
        }

        static var body: Font {
            scaled(17, weight: .regular, style: .body)
        }

        static var caption: Font {
            scaled(12, weight: .regular, style: .caption1)
        }

        static var captionStrong: Font {
            scaled(12, weight: .medium, style: .caption1)
        }
    }

    // MARK: - 间距

    /// 4 的倍数，全项目只允许用这几档（避免 13 / 18 这类随手值）。
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        /// 胶囊
        static let chip: CGFloat = 999
    }

    // MARK: - 阴影

    enum Shadow {
        static let cardRadius: CGFloat = 12
        static let cardY: CGFloat = 4
        static var cardColor: Color { Color.black.opacity(0.06) }
    }

    // MARK: - 触控尺寸

    /// 最小点击区（HIG：≥44×44，T24 的验收项）。
    static let minimumTapSize: CGFloat = 44

    // MARK: - 对比度工具（供测试断言，不用于渲染）

    /// 从 `#RRGGBB` 计算相对亮度（WCAG 2.1 定义）。
    ///
    /// 非法 hex 返回 0，调用方（测试）会因此得到 1.0 的对比度并被断言拦住。
    static func relativeLuminance(hex: String) -> Double {
        guard let components = rgbComponents(hex: hex) else { return 0 }
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let red = linearize(components.red)
        let green = linearize(components.green)
        let blue = linearize(components.blue)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// WCAG 对比度（1…21）。
    static func contrastRatio(_ hexA: String, _ hexB: String) -> Double {
        let first = relativeLuminance(hex: hexA)
        let second = relativeLuminance(hex: hexB)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func rgbComponents(hex: String) -> (red: Double, green: Double, blue: Double)? {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return (red, green, blue)
    }
}

// MARK: - hex 解析

extension Color {
    /// 从 `#RRGGBB` 或 `RRGGBB` 构造；非法值退化为系统灰（绝不崩溃、不留空白）。
    init(hex: String) {
        self.init(uiColor: UIColor(hexString: hex) ?? .systemGray)
    }
}

extension UIColor {
    /// 解析 `#RRGGBB` / `RRGGBB` / `#RRGGBBAA`。非法返回 nil，由调用方决定兜底。
    convenience init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt32(cleaned, radix: 16) else {
            return nil
        }

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if cleaned.count == 8 {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
