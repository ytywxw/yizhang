//
//  EntryFilter.swift
//  一账 / Core / Domain
//
//  职责：账目筛选条件的值类型 + 匹配算法（T09）。6 个维度：时间 / 类型 / 分类 / 账户 / 来源 / 关键词。
//
//  为什么用一个"能匹配任意轻量账目"的协议（`EntryFilterTarget`），而不是直接匹配 `LedgerEntry`：
//  ① Domain 层不允许 `import SwiftData`（架构 §2 目录红线），直接用 `@Model` 会破坏分层；
//  ② 筛选算法是本项目里最容易写错的地方之一（区间边界、转账算不算、关键词大小写），
//     它必须能在**零数据库**的情况下被完整单测——协议 + 值类型让这件事成立；
//  ③ `LedgerEntry` 与首页的 `EntryRowModel` 都能满足它，于是"筛选结果"与"渲染的行"
//     用同一份判定逻辑，不会出现"筛选说命中、列表却没显示"。
//
//  三条硬规则：
//  ① **空集合 = 不限**（不是"全部都不匹配"）。这是筛选类控件最容易搞反的地方；
//  ② **转账按两侧账户都算**：从「支付宝」转到「储蓄卡」，按「储蓄卡」筛也应该能筛到——
//     用户脑子里的"这个账户的钱动过"包含转入；
//  ③ **时间维度与月份是两层过滤**：首页已经限定在本月，时间维度是"本月内的进一步收窄"
//     （本周 / 今天 / 自定义区间）。`monthToDate` 的语义是"本月 1 日到今天"。
//

import Foundation

// MARK: - 可筛选对象

/// 可以被 `EntryFilter` 匹配的轻量对象。
protocol EntryFilterTarget {
    /// 唯一标识。
    var id: UUID { get }
    /// 账目类型。
    var type: EntryType { get }
    /// 账目来源。
    var source: EntrySource { get }
    /// 发生日 `yyyyMMdd`。
    var occurredDay: Int32 { get }
    /// 分类 id（转账为 nil）。
    var categoryID: UUID? { get }
    /// 涉及的账户 id 集合（转账包含转入账户）。
    var accountIDs: Set<UUID> { get }
    /// 备注。
    var note: String { get }
}

// MARK: - 筛选条件

/// 账目筛选条件。
struct EntryFilter: Hashable, Sendable {

    // MARK: 时间维度

    /// 时间范围。
    enum TimeScope: String, CaseIterable, Hashable, Sendable {
        /// 不限（本月全部）
        case all
        /// 今天
        case today
        /// 本周（周一起）
        case week
        /// 本月 1 日到今天
        case monthToDate
        /// 自定义区间
        case custom

        var displayName: String {
            switch self {
            case .all: return "不限"
            case .today: return "今天"
            case .week: return "本周"
            case .monthToDate: return "本月至今"
            case .custom: return "自定义"
            }
        }
    }

    // MARK: 字段

    /// 时间范围。
    var time: TimeScope = .all
    /// 自定义区间起（`0` = 未设置）。
    var customStartDay: Int32 = 0
    /// 自定义区间止（`0` = 未设置）。
    var customEndDay: Int32 = 0
    /// 类型（空 = 不限）。
    var types: Set<EntryType> = []
    /// 分类（空 = 不限）。
    var categoryIDs: Set<UUID> = []
    /// 账户（空 = 不限）。
    var accountIDs: Set<UUID> = []
    /// 来源（空 = 不限）。
    var sources: Set<EntrySource> = []
    /// 关键词（对备注做不区分大小写的包含匹配）。
    var keyword: String = ""

    /// 空条件（不筛选）。
    static let none = EntryFilter()

    init() {}

    // MARK: 判定

    /// 去空白后的关键词。
    var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否有任何维度生效。
    var isActive: Bool {
        time != .all
            || !types.isEmpty
            || !categoryIDs.isEmpty
            || !accountIDs.isEmpty
            || !sources.isEmpty
            || !trimmedKeyword.isEmpty
    }

    /// 生效的维度数量（顶部 chips 的"筛选 (3)"用）。
    var activeDimensionCount: Int {
        var count = 0
        if time != .all { count += 1 }
        if !types.isEmpty { count += 1 }
        if !categoryIDs.isEmpty { count += 1 }
        if !accountIDs.isEmpty { count += 1 }
        if !sources.isEmpty { count += 1 }
        if !trimmedKeyword.isEmpty { count += 1 }
        return count
    }

    /// 时间区间（`nil` = 不限）。
    ///
    /// - Parameter today: 今天（"今天/本周/本月至今"都以它为基准）。
    func dayRange(today: DateOnly) -> ClosedRange<Int32>? {
        switch time {
        case .all:
            return nil
        case .today:
            guard today.key > 0 else { return nil }
            return today.key...today.key
        case .week:
            return DateOnly.weekRange(containing: today)
        case .monthToDate:
            guard today.key > 0 else { return nil }
            let monthStart = DateOnly.monthRange(today.monthKey).lowerBound
            return monthStart...today.key
        case .custom:
            guard customStartDay > 0, customEndDay > 0, customStartDay <= customEndDay else {
                return nil
            }
            return customStartDay...customEndDay
        }
    }

    /// 某条账目是否命中全部维度（维度之间是 AND，同一维度内多选是 OR）。
    func matches<T: EntryFilterTarget>(_ target: T, today: DateOnly) -> Bool {
        if let range = dayRange(today: today), !range.contains(target.occurredDay) {
            return false
        }
        if !types.isEmpty, !types.contains(target.type) {
            return false
        }
        if !categoryIDs.isEmpty {
            guard let categoryID = target.categoryID, categoryIDs.contains(categoryID) else {
                return false
            }
        }
        if !accountIDs.isEmpty {
            // 转账两侧都算：`isDisjoint` 为真说明一个都没命中
            guard !target.accountIDs.isDisjoint(with: accountIDs) else { return false }
        }
        if !sources.isEmpty, !sources.contains(target.source) {
            return false
        }
        let needle = trimmedKeyword
        if !needle.isEmpty, !target.note.localizedStandardContains(needle) {
            return false
        }
        return true
    }

    /// 批量筛选（保持输入顺序）。
    func apply<T: EntryFilterTarget>(_ targets: [T], today: DateOnly) -> [T] {
        guard isActive else { return targets }
        return targets.filter { matches($0, today: today) }
    }

    // MARK: 顶部 chips

    /// 顶部可单独移除的筛选标签。
    struct Chip: Identifiable, Hashable, Sendable {
        /// 稳定的移除键：`time` / `type:expense` / `category:<uuid>` / `account:<uuid>` / `source:todo` / `keyword`
        let id: String
        let title: String
    }

    /// 生成 chips。
    ///
    /// - Parameters:
    ///   - categoryNames: 分类 id → 名称（本层不认识分类对象，名称由调用方给）。
    ///   - accountNames: 账户 id → 名称。
    /// - Returns: 按"时间 → 类型 → 分类 → 账户 → 来源 → 关键词"的固定顺序排列。
    func chips(
        categoryNames: [UUID: String] = [:],
        accountNames: [UUID: String] = [:]
    ) -> [Chip] {
        var result: [Chip] = []

        if time != .all {
            result.append(Chip(id: EntryFilter.chipIDTime, title: timeChipTitle))
        }

        for type in EntryType.allCases where types.contains(type) {
            result.append(Chip(id: "type:\(type.raw)", title: type.displayName))
        }

        // 分类/账户用名称排序，保证 chips 顺序稳定（集合本身无序）
        let categories = categoryIDs
            .map { (id: $0, name: categoryNames[$0] ?? "分类") }
            .sorted { $0.name < $1.name }
        for item in categories {
            result.append(Chip(id: "category:\(item.id.uuidString)", title: item.name))
        }

        let accounts = accountIDs
            .map { (id: $0, name: accountNames[$0] ?? "账户") }
            .sorted { $0.name < $1.name }
        for item in accounts {
            result.append(Chip(id: "account:\(item.id.uuidString)", title: item.name))
        }

        for source in EntrySource.allCases where sources.contains(source) {
            result.append(Chip(id: "source:\(source.raw)", title: "\(source.displayName)记账"))
        }

        if !trimmedKeyword.isEmpty {
            result.append(Chip(id: EntryFilter.chipIDKeyword, title: "“\(trimmedKeyword)”"))
        }

        return result
    }

    static let chipIDTime = "time"
    static let chipIDKeyword = "keyword"

    /// 时间 chip 的文案（自定义区间带上日期）。
    private var timeChipTitle: String {
        switch time {
        case .all: return "不限"
        case .today: return "今天"
        case .week: return "本周"
        case .monthToDate: return "本月至今"
        case .custom:
            guard customStartDay > 0, customEndDay > 0 else { return "自定义" }
            let start = DateOnly(key: customStartDay)
            let end = DateOnly(key: customEndDay)
            return "\(start.month)/\(start.day)–\(end.month)/\(end.day)"
        }
    }

    // MARK: 修改

    /// 移除一个 chip（`id` 不合法时静默忽略——删一个已经不在的 chip 不该报错）。
    mutating func removeChip(id: String) {
        if id == EntryFilter.chipIDTime {
            time = .all
            customStartDay = 0
            customEndDay = 0
            return
        }
        if id == EntryFilter.chipIDKeyword {
            keyword = ""
            return
        }
        if id.hasPrefix("type:") {
            let raw = String(id.dropFirst("type:".count))
            if let type = EntryType(raw: raw) {
                types.remove(type)
            }
            return
        }
        if id.hasPrefix("source:") {
            let raw = String(id.dropFirst("source:".count))
            if let source = EntrySource(raw: raw) {
                sources.remove(source)
            }
            return
        }
        if id.hasPrefix("category:") {
            let raw = String(id.dropFirst("category:".count))
            if let uuid = UUID(uuidString: raw) {
                categoryIDs.remove(uuid)
            }
            return
        }
        if id.hasPrefix("account:") {
            let raw = String(id.dropFirst("account:".count))
            if let uuid = UUID(uuidString: raw) {
                accountIDs.remove(uuid)
            }
        }
    }

    /// 清空全部条件（「清除全部」）。
    mutating func clearAll() {
        self = EntryFilter()
    }

    /// 切换一个分类（选中 ↔ 取消）。
    mutating func toggleCategory(_ id: UUID) {
        if categoryIDs.contains(id) {
            categoryIDs.remove(id)
        } else {
            categoryIDs.insert(id)
        }
    }

    /// 切换一个账户。
    mutating func toggleAccount(_ id: UUID) {
        if accountIDs.contains(id) {
            accountIDs.remove(id)
        } else {
            accountIDs.insert(id)
        }
    }

    /// 切换一个类型。
    mutating func toggleType(_ type: EntryType) {
        if types.contains(type) {
            types.remove(type)
        } else {
            types.insert(type)
        }
    }

    /// 切换一个来源。
    mutating func toggleSource(_ source: EntrySource) {
        if sources.contains(source) {
            sources.remove(source)
        } else {
            sources.insert(source)
        }
    }
}
