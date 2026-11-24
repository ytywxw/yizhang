//
//  DateOnly.swift
//  一账 / Core / Domain
//
//  职责：「自然日」的唯一表示。
//  A2 铁律——自然日是一个整数（`Int32 yyyyMMdd`），不是一个时刻。
//  整数没有时区，因此历史账目永远不会因为用户出差/移民而整体跑一天。
//
//  为什么不用 `Date`：
//  1. `Date` 是绝对时刻，`startOfDay` 的结果依赖时区与 DST，跨时区解析会漂移；
//  2. iOS 17 的 `#Predicate` 对 `Optional<Date>` 支持不稳，整数比较永远可靠；
//  3. `#Predicate` 内不允许调用 `Calendar`，整数区间谓词（`>= 20251101 && <= 20251130`）永不出错。
//
//  `Calendar` 在本文件只出现 2 处：`init(_:calendar:)`（时刻 → 自然日）与 `date`（自然日 → 时刻，
//  取当天 12:00 以避开 DST 边界）。其余全部是纯整数运算（Howard Hinnant 的 civil/days 算法），
//  因此任何时区、任何 locale 下结果完全一致，可 100% 单测。
//

import Foundation

/// 只表示"哪一天"的值类型，唯一存储 `yyyyMMdd` 整数。
struct DateOnly: Hashable, Comparable, Codable, Sendable {

    /// 哨兵：无效日 / 未设置。所有"日"字段用 0 表示"无"，避免 Optional 谓词。
    static let zero = DateOnly(key: 0)

    /// `yyyyMMdd`，例如 2025-11-20 → `20251120`。
    let key: Int32

    init(key: Int32) {
        self.key = key
    }

    /// 全项目唯一的「时刻 → 自然日」换算点。
    ///
    /// - Parameters:
    ///   - date: 任意时刻。
    ///   - calendar: 默认当前日历（含当前时区），测试可注入固定时区。
    init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        self.key = DateOnly.makeKey(year: year, month: month, day: day)
    }

    /// 用年月日构造；日期不真实（如 2 月 30 日）时返回 nil。
    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        guard day <= DateOnly.daysInMonth(year: year, month: month) else { return nil }
        self.key = DateOnly.makeKey(year: year, month: month, day: day)
    }

    // MARK: - 分解

    var year: Int { Int(key / 10_000) }
    var month: Int { Int(key / 100) % 100 }
    var day: Int { Int(key % 100) }

    /// `yyyyMM`，例如 202511。
    var monthKey: Int32 { Int32(year * 100 + month) }

    /// 是否是一个真实的日期（`zero` 与越界值返回 false）。
    var isValid: Bool {
        guard key > 0, (1...9999).contains(year), (1...12).contains(month) else { return false }
        return day >= 1 && day <= DateOnly.daysInMonth(year: year, month: month)
    }

    // MARK: - 自然日 → 时刻

    /// 供 `DatePicker` 绑定与展示使用。
    ///
    /// 取当天 **12:00** 而非 00:00：某些时区存在 00:00 不存在（夏令时跳变从 00:00 开始）的情况，
    /// 正午永远不会落在跳变窗口里。
    var date: Date {
        guard key > 0 else { return Date(timeIntervalSince1970: 0) }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        components.minute = 0
        components.second = 0
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - 推进

    /// 加减天数（纯整数运算，跨月跨年由 civil 算法保证正确）。
    func adding(days: Int) -> DateOnly {
        guard key > 0 else { return self }
        let absoluteDays = DateOnly.daysFromCivil(year: year, month: month, day: day) + days
        let civil = DateOnly.civilFromDays(absoluteDays)
        guard (1...9999).contains(civil.year) else { return self }
        return DateOnly(key: DateOnly.makeKey(year: civil.year, month: civil.month, day: civil.day))
    }

    /// 加减月份（按自身日号为锚定日，目标月没有该日时取月末）。
    ///
    /// 注意：这是"自然推进"，不保留原始锚定日。订阅场景必须使用 `CycleAdvancer`，
    /// 那里会带上 `billingAnchorDay`，从而避免 1/31 → 2/28 → 3/28 的永久漂移。
    func adding(months: Int) -> DateOnly {
        guard key > 0 else { return self }
        return DateOnly.advancingMonths(from: self, months: months, anchorDay: day)
    }

    /// 加减年份（等价于 12 倍月份推进，2/29 遇平年夹紧到 2/28）。
    func adding(years: Int) -> DateOnly {
        let (months, overflow) = 12.multipliedReportingOverflow(by: years)
        guard !overflow else { return self }
        return adding(months: months)
    }

    /// 以 `anchorDay` 为基准日推进 `months` 个月。
    ///
    /// 这是 R-SUB-8「期末对齐」的唯一实现：目标月没有 `anchorDay` 时取该月最后一天，
    /// 且**下一次推进仍从 `anchorDay` 推算**（调用方传入不变的锚定日即可），
    /// 因此 1/31 →(+1M) 2/28 →(+1M) 3/31，而不是 3/28。
    static func advancingMonths(from base: DateOnly, months: Int, anchorDay: Int) -> DateOnly {
        guard base.key > 0 else { return base }

        // 用整数做"年月总序号"运算，支持负数月份且不依赖 Double
        let totalMonths = (base.year * 12) + (base.month - 1) + months
        let yearIndex = totalMonths >= 0 ? totalMonths / 12 : -(((-totalMonths) + 11) / 12)
        let monthIndex = totalMonths - yearIndex * 12  // 0...11

        let targetYear = yearIndex
        let targetMonth = monthIndex + 1
        guard (1...9999).contains(targetYear) else { return base }

        let lastDayOfMonth = daysInMonth(year: targetYear, month: targetMonth)
        let clampedAnchor = min(max(anchorDay, 1), lastDayOfMonth)
        return DateOnly(key: makeKey(year: targetYear, month: targetMonth, day: clampedAnchor))
    }

    // MARK: - 区间

    /// 某个月的整数区间，例如 `202511 → 20251101...20251130`。
    static func monthRange(_ monthKey: Int32) -> ClosedRange<Int32> {
        let year = Int(monthKey / 100)
        let month = Int(monthKey % 100)
        let lastDay = daysInMonth(year: year, month: month)
        let first = monthKey * 100 + 1
        return first...(monthKey * 100 + Int32(lastDay))
    }

    /// 包含指定日的那一周（周一 … 周日）的整数区间，可跨月、跨年。
    static func weekRange(containing dateOnly: DateOnly) -> ClosedRange<Int32> {
        guard dateOnly.key > 0 else { return 0...0 }
        let mondayOffset = dateOnly.weekdayIndexMondayFirst
        let monday = dateOnly.adding(days: -mondayOffset)
        let sunday = dateOnly.adding(days: 6 - mondayOffset)
        return monday.key...sunday.key
    }

    /// 周一为 0、周日为 6。1970-01-01 是周四，所以 `(z + 3) mod 7` 正好给出周一为 0 的索引。
    var weekdayIndexMondayFirst: Int {
        guard key > 0 else { return 0 }
        let absoluteDays = DateOnly.daysFromCivil(year: year, month: month, day: day)
        return ((absoluteDays + 3) % 7 + 7) % 7
    }

    /// "周一" … "周日"
    var weekdayName: String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return names[weekdayIndexMondayFirst]
    }

    // MARK: - 便利判定

    var isToday: Bool { self == DateOnly(Date()) }

    var isFuture: Bool { self > DateOnly(Date()) }

    var isPast: Bool { self < DateOnly(Date()) }

    /// "11月20日"
    var displayString: String { "\(month)月\(day)日" }

    /// "2025年11月20日"
    var fullDisplayString: String { "\(year)年\(month)月\(day)日" }

    /// "2025-11-20"，用于 CSV / JSON 导出
    var isoString: String {
        let monthText = month < 10 ? "0\(month)" : "\(month)"
        let dayText = day < 10 ? "0\(day)" : "\(day)"
        return "\(year)-\(monthText)-\(dayText)"
    }

    // MARK: - 纯整数日历运算（Howard Hinnant civil_from_days / days_from_civil）

    static func makeKey(year: Int, month: Int, day: Int) -> Int32 {
        Int32(year * 10_000 + month * 100 + day)
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// 固定表 + 闰年判定，不依赖 `Calendar`，任何时区下结果一致。
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            return isLeapYear(year) ? 29 : 28
        default:
            return 30
        }
    }

    /// 公历日期 → 距 1970-01-01 的天数（可为负）。
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400                       // [0, 399]
        let shiftedMonth = (month + 9) % 12                            // 3 月为 0
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1         // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// 距 1970-01-01 的天数 → 公历日期。
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097                          // [0, 146096]
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth + (shiftedMonth < 10 ? 3 : -9)
        return (year + (month <= 2 ? 1 : 0), month, day)
    }

    // MARK: - Comparable

    static func < (lhs: DateOnly, rhs: DateOnly) -> Bool {
        lhs.key < rhs.key
    }
}

extension DateOnly: CustomStringConvertible {
    var description: String { key == 0 ? "DateOnly.zero" : isoString }
}
