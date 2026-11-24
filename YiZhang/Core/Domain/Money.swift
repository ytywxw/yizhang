//
//  Money.swift
//  一账 / Core / Domain
//
//  职责：金额的唯一表示。
//  A1 铁律——全项目金额只有一种形态：`Int64` 分。本文件是金额进入系统的唯一入口，
//  任何地方都不得出现 `Double` / `Float` / `Decimal` 参与金额运算（Decimal 仅在格式化时
//  作为 NumberFormatter 的输入出现，且由 `Int64` 精确构造，不参与四则运算）。
//
//  设计要点：
//  1. `parse` 全程字符串解析，逐位累加并做溢出检查，绝不经过浮点；
//  2. `formatted` 缓存 `NumberFormatter`（创建成本高），并用 NSLock 保护其非线程安全性；
//  3. 运算符在溢出时"饱和"到 `Int64` 边界而不是崩溃——记账 App 宁可显示一个明显错误的
//     极端数字，也不能因为一次乘法溢出让用户闪退丢数据；需要精确判定溢出时用
//     `adding(_:)` / `subtracting(_:)`（返回 nil）。
//

import Foundation

/// 以「分」为唯一存储的金额值类型。
///
/// `Money` 允许为负（账户余额、收支差额等场景需要），业务层（如手工记账）负责校验 `> 0`。
struct Money: Hashable, Comparable, Codable, Sendable {

    /// 展示风格。金额的"元"文本只在展示层出现，内部永远是分。
    enum Style: String, CaseIterable, Codable, Sendable {
        /// 带货币符号，如 `¥12.50`
        case standard
        /// 带正号（零与负数保持原样），如 `+¥12.50`
        case signed
        /// 不带货币符号，如 `12.50`
        case noSymbol
    }

    /// 唯一存储：分。
    let cents: Int64

    init(cents: Int64) {
        self.cents = cents
    }

    static let zero = Money(cents: 0)

    // MARK: - 解析

    /// 把用户输入的金额文本解析为 `Money`。
    ///
    /// 支持：`"12"`、`"12.5"`、`"12.50"`、`".5"`、`"0.05"`、前导 `+`、千分位 `"1,234.50"`、
    /// 前置货币符号 `"¥12.50"`（用户从别处粘贴时常见）。
    ///
    /// 拒绝：空串/纯空白、负数、多于两位小数、多个小数点、含非数字字符、超出 `Int64` 范围。
    ///
    /// 实现方式：逐字符累加（`cents = yuan * 100 + fraction`），每一步都用
    /// `multipliedReportingOverflow` / `addingReportingOverflow` 检查，**永不经过浮点**。
    /// 这是 A1 的核心实现，不允许改成 `Double(raw)` 这类写法。
    static func parse(_ raw: String) -> Money? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 容忍货币符号前缀（粘贴场景）
        for symbol in ["¥", "￥"] where text.hasPrefix(symbol) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
            break
        }

        // 容忍前导 +，但明确拒绝负号：记账输入不应接受负数金额
        if text.hasPrefix("+") {
            text.removeFirst()
        }
        guard !text.isEmpty, !text.hasPrefix("-") else { return nil }

        let segments = text.components(separatedBy: ".")
        guard segments.count <= 2 else { return nil }  // "1.2.3" → 非法

        let integerSegment = segments[0]
        let fractionSegment = segments.count == 2 ? segments[1] : ""

        // 两位以上的小数无法用"分"精确表示，直接拒绝（不四舍五入，避免悄悄改变用户输入）
        guard fractionSegment.count <= 2 else { return nil }
        guard !(integerSegment.isEmpty && fractionSegment.isEmpty) else { return nil }  // "." → 非法

        guard let integerDigits = normalizedIntegerDigits(integerSegment) else { return nil }
        guard fractionSegment.allSatisfy(isASCIIDigit) else { return nil }

        // 整数部分逐位累加
        var yuanValue: Int64 = 0
        for character in integerDigits {
            guard let digit = Int64(String(character)) else { return nil }
            let (timesTen, overflowOnShift) = yuanValue.multipliedReportingOverflow(by: 10)
            guard !overflowOnShift else { return nil }
            let (plusDigit, overflowOnAdd) = timesTen.addingReportingOverflow(digit)
            guard !overflowOnAdd else { return nil }
            yuanValue = plusDigit
        }

        let (scaledCents, overflowOnScale) = yuanValue.multipliedReportingOverflow(by: 100)
        guard !overflowOnScale else { return nil }

        // 小数部分补齐到两位（"12.5" 的 5 是 5 角 = 50 分）
        var fractionCents: Int64 = 0
        if !fractionSegment.isEmpty {
            let padded = fractionSegment + String(repeating: "0", count: 2 - fractionSegment.count)
            for character in padded {
                guard let digit = Int64(String(character)) else { return nil }
                fractionCents = fractionCents * 10 + digit
            }
        }

        let (totalCents, overflowOnTotal) = scaledCents.addingReportingOverflow(fractionCents)
        guard !overflowOnTotal else { return nil }
        return Money(cents: totalCents)
    }

    /// 校验并去掉整数部分里的千分位逗号。空串代表用户只输入了小数（如 `".5"`）。
    private static func normalizedIntegerDigits(_ segment: String) -> String? {
        guard !segment.isEmpty else { return "" }

        guard segment.contains(",") else {
            guard segment.allSatisfy(isASCIIDigit) else { return nil }
            return segment
        }

        let groups = segment.components(separatedBy: ",")
        guard groups.count >= 2 else { return nil }
        for (index, group) in groups.enumerated() {
            guard !group.isEmpty, group.allSatisfy(isASCIIDigit) else { return nil }
            // 第一组 1...3 位，其余每组必须正好 3 位（"1,234.50" 合法，"1,2,3" 非法）
            if index == 0 {
                guard group.count <= 3 else { return nil }
            } else {
                guard group.count == 3 else { return nil }
            }
        }
        return groups.joined()
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    // MARK: - 展示

    /// 纯"元"文本，固定两位小数，如 `1250 → "12.50"`、`5 → "0.05"`、`-1250 → "-12.50"`。
    ///
    /// 用 `magnitude`（`UInt64`）取绝对值，因此 `Int64.min` 也不会溢出。
    var yuanString: String {
        let magnitude = cents.magnitude
        let yuan = magnitude / 100
        let fraction = magnitude % 100
        let sign = cents < 0 ? "-" : ""
        let fractionText = fraction < 10 ? "0\(fraction)" : "\(fraction)"
        return sign + String(yuan) + "." + fractionText
    }

    /// 取整到元的数字文本（不含货币符号），如 `1250 → "12"`、`-1250 → "-12"`。
    ///
    /// 专门给"本来就是折算/取整过的数字"用（订阅的每月固定支出）：
    /// 那里显示 `¥234.00` 会给出一种"精确到分"的假精度，而实际口径是"约 234 元"。
    var wholeYuanDigits: String {
        let magnitude = cents.magnitude
        let sign = cents < 0 ? "-" : ""
        return sign + String(magnitude / 100)
    }

    /// 本地化后的展示文本，如 `"¥12.50"`。
    ///
    /// `NumberFormatter` 创建成本高且非线程安全，所以缓存实例并加锁使用。
    func formatted(style: Style = .standard) -> String {
        let decimalValue = Decimal(cents) / Decimal(100)
        let number = NSDecimalNumber(decimal: decimalValue)

        Money.formatterLock.lock()
        defer { Money.formatterLock.unlock() }
        let formatter = style == .noSymbol ? Money.plainFormatter : Money.currencyFormatter
        let text = formatter.string(from: number) ?? yuanString

        // 正数才补 "+"，负数由 formatter 自带 "-"，零不加号
        if style == .signed, cents > 0 {
            return "+" + text
        }
        return text
    }

    /// 无障碍朗读文本：按「元 / 角 / 分」念出来，避免读成"十二点五"。
    var accessibilityText: String {
        let magnitude = cents.magnitude
        let yuan = magnitude / 100
        let jiao = (magnitude % 100) / 10
        let fen = magnitude % 10

        var parts: [String] = []
        if yuan > 0 { parts.append("\(yuan)元") }
        if jiao > 0 { parts.append("\(jiao)角") }
        if fen > 0 { parts.append("\(fen)分") }
        if parts.isEmpty { parts.append("0元") }

        return (cents < 0 ? "负" : "") + parts.joined()
    }

    // MARK: - 运算（溢出安全）

    var isZero: Bool { cents == 0 }
    var isPositive: Bool { cents > 0 }
    var isNegative: Bool { cents < 0 }

    /// 精确加法；溢出返回 nil。
    func adding(_ other: Money) -> Money? {
        let (sum, overflow) = cents.addingReportingOverflow(other.cents)
        return overflow ? nil : Money(cents: sum)
    }

    /// 精确减法；溢出返回 nil。
    func subtracting(_ other: Money) -> Money? {
        let (difference, overflow) = cents.subtractingReportingOverflow(other.cents)
        return overflow ? nil : Money(cents: difference)
    }

    /// 取相反数；`Int64.min` 无法取反时返回 nil。
    func negated() -> Money? {
        let (value, overflow) = Int64.zero.subtractingReportingOverflow(cents)
        return overflow ? nil : Money(cents: value)
    }

    /// 饱和加法运算符：溢出时夹到 `Int64` 边界，绝不崩溃。
    static func + (lhs: Money, rhs: Money) -> Money {
        let (sum, overflow) = lhs.cents.addingReportingOverflow(rhs.cents)
        guard overflow else { return Money(cents: sum) }
        return Money(cents: rhs.cents >= 0 ? Int64.max : Int64.min)
    }

    /// 饱和减法运算符：溢出时夹到 `Int64` 边界，绝不崩溃。
    static func - (lhs: Money, rhs: Money) -> Money {
        let (difference, overflow) = lhs.cents.subtractingReportingOverflow(rhs.cents)
        guard overflow else { return Money(cents: difference) }
        return Money(cents: rhs.cents <= 0 ? Int64.max : Int64.min)
    }

    static prefix func - (value: Money) -> Money {
        let (negated, overflow) = Int64.zero.subtractingReportingOverflow(value.cents)
        return Money(cents: overflow ? Int64.min : negated)
    }

    static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.cents < rhs.cents
    }

    // MARK: - 缓存的格式化器

    private static let formatterLock = NSLock()

    private static let currencyFormatter: NumberFormatter = makeFormatter(usesCurrencyStyle: true)

    private static let plainFormatter: NumberFormatter = makeFormatter(usesCurrencyStyle: false)

    private static func makeFormatter(usesCurrencyStyle: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = usesCurrencyStyle ? .currency : .decimal
        formatter.currencySymbol = "¥"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter
    }
}

extension Money: CustomStringConvertible {
    var description: String { yuanString }
}
