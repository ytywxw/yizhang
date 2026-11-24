//
//  AmountKeypad.swift
//  一账 / Core / DesignSystem
//
//  职责：自建金额键盘（R-IN-1 / T07）——`0-9` `.` `⌫` + 底部「今天 / 昨天」日期快捷键。
//
//  为什么不用系统数字键盘（`.keyboardType(.decimalPad)`）：
//  ① 系统键盘没有「⌫」，金额打错只能长按删除，且无法在键帽上做 44pt 的可控布局；
//  ② 系统键盘会顶起页面，而记账页需要「金额大字始终可见 + 键盘常驻」，固定布局才稳；
//  ③ 底部要放「今天 / 昨天」这类日期快捷键，系统键盘结构上不允许。
//
//  两条硬约束：
//  ① **高度固定**（`totalHeight`）。金额页最怕的就是"键盘跳一下、上面内容全飘走"，
//     所以键帽用绝对字号（`.system(size:)`）而不是相对字号——Dynamic Type 放大时
//     这一块不参与缩放，宁可字号不变，也不让布局崩塌（T24 会用 `Font.custom(relativeTo:)`
//     给出上限后统一处理）；
//  ② **输入规则唯一实现**（`AmountInput`）。非法输入（`1.2.3`、`0.005`、`00012`）
//     在这里被挡掉，`EntryViewModel` 只负责把结果读成 `Money`。
//

import SwiftUI

// MARK: - 键

/// 一个键帽的语义。
enum AmountKey: Hashable, Sendable {
    /// 数字 0…9
    case digit(Int)
    /// 小数点
    case decimal
    /// 退格
    case backspace

    var title: String {
        switch self {
        case .digit(let value): return "\(value)"
        case .decimal: return "."
        case .backspace: return "⌫"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .digit(let value): return "\(value)"
        case .decimal: return "小数点"
        case .backspace: return "删除"
        }
    }
}

// MARK: - 输入规则（唯一实现，纯函数）

/// 金额文本的编辑规则。
///
/// 全部是纯函数：输入"现在是 `12.3`，按下 `4`"，输出"`12.34`"。
/// 因此"最多两位小数""不许出现两个小数点""不许 `00012`"这些规则可以被单测直接钉住，
/// 而不需要起 UI 去点键帽。
enum AmountInput {

    /// 整数部分最多几位（9 位 → 最大 999,999,999 元，远超个人记账量级）。
    static let maximumIntegerDigits = 9

    /// 小数部分最多几位（分 → 2 位）。
    static let maximumFractionDigits = 2

    /// 空文本时的占位（显示用）。
    static let placeholder = "0"

    /// 按下一个键之后的新文本。非法按键**返回原文本**（不做任何事），绝不抛错。
    ///
    /// - Parameters:
    ///   - key: 键帽。
    ///   - text: 当前文本（不含 `¥`）。
    /// - Returns: 新文本。
    static func apply(_ key: AmountKey, to text: String) -> String {
        switch key {
        case .digit(let value):
            return appendDigit(value, to: text)
        case .decimal:
            return appendDecimalPoint(to: text)
        case .backspace:
            return backspace(text)
        }
    }

    /// 追加数字。
    private static func appendDigit(_ digit: Int, to text: String) -> String {
        guard (0...9).contains(digit) else { return text }
        let digitText = "\(digit)"

        if let pointIndex = text.firstIndex(of: ".") {
            // 小数部分：最多 2 位
            let fraction = text[text.index(after: pointIndex)...]
            guard fraction.count < maximumFractionDigits else { return text }
            return text + digitText
        }

        // 整数部分：`0` 不能被追加成 `05`（用户按 0 再按 5，期望是 5 不是 05）
        if text == "0" {
            return digitText
        }
        guard text.count < maximumIntegerDigits else { return text }
        return text + digitText
    }

    /// 追加小数点（只允许一个；空文本自动补 `0`）。
    private static func appendDecimalPoint(to text: String) -> String {
        guard !text.contains(".") else { return text }
        if text.isEmpty { return "0." }
        return text + "."
    }

    /// 退格：一位一位删，删到空就停在空。
    private static func backspace(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var trimmed = String(text.dropLast())
        // `0.` 退格成 `0` 是自然的；`0` 再退格成空也是自然的，不需要特殊处理
        if trimmed.isEmpty { trimmed = "" }
        return trimmed
    }

    /// 文本 → 金额。空文本 / 只有小数点 / 非法文本返回 nil。
    ///
    /// 转换只走 `Money.parse`（A1：分 → 元只有一处实现），本文件不做除法。
    static func money(from text: String) -> Money? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "0." else {
            // `0.` 语义上就是 0 元，交给 `Money.parse` 处理
            return trimmed.isEmpty ? nil : Money.parse(trimmed)
        }
        return Money.parse(trimmed)
    }

    /// 金额 → 编辑文本（编辑模式回填用）。分恒为整数，因此永远能精确还原。
    static func text(from money: Money) -> String {
        let digits = Money(cents: money.cents < 0 ? 0 : money.cents).yuanString
        // `yuanString` 是 "12.30" 这种固定两位；编辑时去掉多余的 `0` 更符合手输习惯
        if digits.hasSuffix(".00") {
            return String(digits.dropLast(3))
        }
        if digits.hasSuffix("0") {
            return String(digits.dropLast())
        }
        return digits
    }

    /// 展示文本：空 → 占位符；`0.` → `0.`（保留小数点，让用户看到自己按了什么）。
    static func displayText(for text: String) -> String {
        text.isEmpty ? placeholder : text
    }
}

// MARK: - 金额显示

/// 金额大字（40pt 等宽数字，`¥` 与数字基线对齐）。
struct AmountDisplayView: View {

    /// 金额文本（不含 `¥`）。
    let text: String

    /// 强调色（转账时用灰色，其余用主文本色）。
    var tone: MoneyText.Tone = .expense

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            Text("¥")
                .font(Theme.Typography.amountMedium)
                .foregroundStyle(tone == .transfer ? Theme.Semantic.transfer : .secondary)

            Text(AmountInput.displayText(for: text))
                .font(Theme.Typography.amount)
                .monospacedDigit()
                .foregroundStyle(isPlaceholder ? Color.secondary.opacity(0.45) : tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(Text(accessibilityText))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.12), value: text)
    }

    private var isPlaceholder: Bool { text.isEmpty }

    private var accessibilityText: String {
        guard let money = AmountInput.money(from: text) else { return "金额 0 元" }
        return "金额 \(money.accessibilityText)"
    }
}

// MARK: - 键盘

/// 固定高度的金额键盘。
///
/// 布局（3 列 4 行 + 一行日期快捷键）：
/// ```
/// 1   2   3
/// 4   5   6
/// 7   8   9
/// .   0   ⌫
/// 今天     昨天
/// ```
struct AmountKeypad: View {

    /// 按键回调（由 `EntryViewModel.press(_:)` 处理）。
    var onKey: (AmountKey) -> Void

    /// 当前选中日期（高亮「今天 / 昨天」）。
    var selectedDay: DateOnly

    /// 今天（由外部注入，方便测试与预览固定时间）。
    var today: DateOnly

    /// 选择日期回调。
    var onSelectDay: (DateOnly) -> Void

    /// 键盘总高度（固定值：50 × 4 + 8 × 4 + 44 = 276）。
    static var totalHeight: CGFloat {
        keyHeight * 4 + spacing * 4 + Theme.minimumTapSize
    }

    private static let keyHeight: CGFloat = 50
    private static let spacing: CGFloat = 8

    private var rows: [[AmountKey]] {
        [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [.decimal, .digit(0), .backspace]
        ]
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.spacing) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }

            HStack(spacing: Self.spacing) {
                dayButton(title: "今天", day: today)
                dayButton(title: "昨天", day: today.adding(days: -1))
            }
            .frame(height: Theme.minimumTapSize)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.top, Theme.Spacing.xs)
        .frame(height: Self.totalHeight, alignment: .top)
        .background(
            Theme.Semantic.pageBackground
                .ignoresSafeArea(edges: .bottom)
        )
        .accessibilityIdentifier("entry.keypad")
    }

    // MARK: - 键帽

    private func keyButton(_ key: AmountKey) -> some View {
        Button {
            onKey(key)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Semantic.cardBackground)

                if key == .backspace {
                    Image(systemName: "delete.left")
                        // 绝对字号：键盘区不参与 Dynamic Type 缩放（见文件头说明）
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.primary)
                } else {
                    Text(key.title)
                        .font(.system(size: 26, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            // 高度固定，宽度均分
            .frame(maxWidth: .infinity)
            .frame(height: Self.keyHeight)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(KeypadButtonStyle())
        .accessibilityLabel(Text(key.accessibilityLabel))
        .accessibilityIdentifier("entry.key.\(keyIdentifier(key))")
    }

    private func dayButton(title: String, day: DateOnly) -> some View {
        let isSelected = day == selectedDay
        return Button {
            onSelectDay(day)
        } label: {
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.minimumTapSize)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Theme.Semantic.cardBackground)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(KeypadButtonStyle())
        .accessibilityLabel(Text(isSelected ? "\(title)，已选中" : "记为\(title)"))
        .accessibilityAddTraits(isSelected ? .isSelected : AccessibilityTraits())
        .accessibilityIdentifier("entry.day.\(title)")
    }

    private func keyIdentifier(_ key: AmountKey) -> String {
        switch key {
        case .digit(let value): return "\(value)"
        case .decimal: return "dot"
        case .backspace: return "delete"
        }
    }
}

// MARK: - 键帽按压反馈

/// 键帽按下时轻微变暗 + 缩放（系统键盘的手感，纯视觉，无业务含义）。
private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 预览

#Preview("金额键盘") {
    VStack(spacing: Theme.Spacing.md) {
        AmountDisplayView(text: "28.5")
            .padding(.horizontal, Theme.Spacing.md)
        Spacer(minLength: 0)
        AmountKeypad(
            onKey: { _ in },
            selectedDay: DateOnly(year: 2026, month: 11, day: 21) ?? .zero,
            today: DateOnly(year: 2026, month: 11, day: 21) ?? .zero,
            onSelectDay: { _ in }
        )
    }
    .background(Theme.Semantic.pageBackground)
}
