//
//  MoneyText.swift
//  一账 / Core / DesignSystem
//
//  职责：金额文本的唯一渲染入口。
//
//  为什么必须统一（不允许各视图自己 `Text("¥\(x)")`）：
//  ① 等宽数字：列表滚动时金额不能因为字形宽度变化而抖动（`.monospacedDigit()`）；
//  ② 颜色语义固定：支出=主文本色、收入=绿、转账=灰，避免"某页支出是红的"这种不一致；
//  ③ 分 → 元的转换只走 `Money`（A1：任何地方都不许自己除 100 拼字符串）；
//  ④ 无障碍朗读走 `Money.accessibilityText`，读成"十二元五角"而不是"十二点五"。
//

import SwiftUI

/// 金额文本。
struct MoneyText: View {

    /// 语境色调。
    enum Tone: Hashable, Sendable {
        /// 支出：主文本色
        case expense
        /// 收入：绿
        case income
        /// 转账：灰
        case transfer
        /// 中性（账户余额、统计总量等）：主文本色
        case neutral

        var color: Color {
            switch self {
            case .expense: return Theme.Semantic.expense
            case .income: return Theme.Semantic.income
            case .transfer: return Theme.Semantic.transfer
            case .neutral: return Color.primary
            }
        }

        /// 由账目类型推色调（转账单独处理）。
        init(type: EntryType) {
            switch type {
            case .expense: self = .expense
            case .income: self = .income
            case .transfer: self = .transfer
            }
        }
    }

    /// 字号档位。
    enum Emphasis: Hashable, Sendable {
        /// 40pt：首页概览卡、记账输入页
        case large
        /// 28pt：详情页
        case medium
        /// 17pt：列表行
        case small
        /// 17pt 常规字重
        case body

        var font: Font {
            switch self {
            case .large: return Theme.Typography.amount
            case .medium: return Theme.Typography.amountMedium
            case .small: return Theme.Typography.amountSmall
            case .body: return Theme.Typography.body.monospacedDigit()
            }
        }
    }

    let amount: Money
    var tone: Tone = .expense
    var emphasis: Emphasis = .small
    /// 是否显示 +/- 号（收入默认 +、支出 -，由 `tone` 决定方向）
    var showsSign: Bool = false
    /// 是否显示 ¥
    var showsSymbol: Bool = true
    /// 是否显示小数部分。`false` 时只显示整元（用于取了整的折算值，如订阅「约 ¥234」）。
    var showsFraction: Bool = true
    /// 是否使用紧凑格式（≥1 万显示「1.2万」，≥1 亿显示「1.2亿」）
    var compact: Bool = false

    var body: some View {
        Text(displayText)
            .font(emphasis.font)
            .monospacedDigit()
            .foregroundStyle(tone.color)
            .accessibilityLabel(Text(amount.accessibilityText))
    }

    /// 展示文本。所有分 → 元转换都经 `Money`，本文件不做除法。
    var displayText: String {
        if compact {
            return MoneyText.compactString(amount, showsSymbol: showsSymbol, sign: signPrefix)
        }
        if !showsFraction {
            // 整元：分 → 元的取整同样只走 `Money`（A1），避免这里自己除 100
            return signPrefix + MoneyText.wholeYuanText(amount, showsSymbol: showsSymbol)
        }
        let base = amount.formatted(style: showsSymbol ? .standard : .noSymbol)
        return signPrefix + base
    }

    /// 符号前缀：由 `tone` 语义决定，而不是由金额正负决定——
    /// 支出金额本身存的是正数，语义上的"出账"要靠前缀表达。
    private var signPrefix: String {
        guard showsSign else { return "" }
        switch tone {
        case .expense: return "-"
        case .income: return "+"
        case .transfer, .neutral: return ""
        }
    }

    // MARK: - 整元文本

    /// 整元文本（取整后不带小数）。供 `Text + Text` 拼接使用——
    /// 拼接出来的单个 `Text` 内部不可能被 `Spacer` 撑开，于是「约」永远紧贴数字。
    ///
    /// - Parameters:
    ///   - amount: 金额。
    ///   - showsSymbol: 是否带 `¥`。
    static func wholeYuanText(_ amount: Money, showsSymbol: Bool = true) -> String {
        (showsSymbol ? "¥" : "") + amount.wholeYuanDigits
    }

    // MARK: - 紧凑格式（纯整数运算，绝不经过 Double）

    /// 把金额转成紧凑文本：
    /// - ≥ 1 亿元 → `"1.2亿"`
    /// - ≥ 1 万元 → `"1.2万"`
    /// - 否则正常两位小数（`"¥9,999.00"` 的分组由 `Money.formatted` 决定，本项目关闭分组）
    ///
    /// - Parameters:
    ///   - amount: 金额。
    ///   - showsSymbol: 是否带 `¥`（万/亿后缀时不带，避免 "¥1.2万" 这种冗余）。
    ///   - sign: 前缀（"-" / "+" / ""）。
    static func compactString(_ amount: Money, showsSymbol: Bool = true, sign: String = "") -> String {
        // 单位换算：1 元 = 100 分，1 万 = 10^6 分，1 亿 = 10^10 分
        let centsPerWan: UInt64 = 1_000_000
        let centsPerYi: UInt64 = 10_000_000_000
        let magnitude = amount.cents.magnitude

        if magnitude >= centsPerYi {
            let yi = magnitude / centsPerYi
            let tenth = (magnitude % centsPerYi) / (centsPerYi / 10)
            return sign + "\(yi)" + (tenth > 0 ? ".\(tenth)" : "") + "亿"
        }
        if magnitude >= centsPerWan {
            let wan = magnitude / centsPerWan
            let tenth = (magnitude % centsPerWan) / (centsPerWan / 10)
            return sign + "\(wan)" + (tenth > 0 ? ".\(tenth)" : "") + "万"
        }
        return sign + amount.formatted(style: showsSymbol ? .standard : .noSymbol)
    }
}

// MARK: - 预览

#Preview("金额文本") {
    VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
        MoneyText(amount: Money(cents: 2800), tone: .expense, emphasis: .large, showsSign: true)
        MoneyText(amount: Money(cents: 500_000), tone: .income, emphasis: .medium, showsSign: true)
        MoneyText(amount: Money(cents: 12_345_678), tone: .neutral, emphasis: .small, compact: true)
        MoneyText(amount: Money(cents: 5), tone: .transfer, emphasis: .body)
    }
    .padding()
}
