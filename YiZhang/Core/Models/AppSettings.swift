//
//  AppSettings.swift
//  一账 / Core / Models
//
//  职责：单例设置（架构 §3.2）。纯数据 + 便捷计算属性。
//
//  为什么这些状态放 SwiftData 而不是 UserDefaults（架构 §7）：
//  - `defaultAccountID` / `recentCategoryIDs`：换机后"上次用的账户""最近用的分类"应该在，
//    且它们引用 Category / Account 的 UUID，必须与数据同源；
//  - 通知开关、外观：同步到新设备是用户预期。
//  而"当前浏览月份"是纯 UI 偏好（丢了只是体验差一点），所以放 UserDefaults + VM 内存。
//
//  注意：**不加唯一约束**去保证"只有一条设置"。单例由 `SeedData` 幂等保证（T05），
//  不用 `@Attribute(.unique)`（CloudKit 禁止 + upsert 语义会静默覆盖）。
//
//  CloudKit 形状约束同 `LedgerEntry`。
//

import Foundation
import SwiftData

/// 全局设置（库存一条，由种子数据保证）。
@Model
final class AppSettings {

    // MARK: - 标量字段

    var id: UUID = UUID()

    /// 上次使用的账户 id（F-ACC-07，记账页默认账户）。
    var defaultAccountID: UUID? = nil

    /// 最近使用的分类 id，最多 6 个，**有序**（R-IN-2：只填金额时自动取第一个）。
    var recentCategoryIDs: [UUID]? = nil

    /// 当前浏览月份键 `yyyyMM`（展示兜底，主存储在 UserDefaults + VM 内存）。
    var currentMonthKey: Int32 = 0

    /// 订阅扣费提醒开关。
    var subscriptionReminderEnabled: Bool = true

    /// 待办提醒开关。
    var todoReminderEnabled: Bool = true

    /// `Appearance` 的 raw 值：system / light / dark。
    var appearanceRaw: String = Appearance.system.raw

    /// 是否已完成首启种子（`SeedData` 幂等判据）。
    var hasSeeded: Bool = false

    /// 上次结算扫描时间（节流用）。
    var lastSweptAt: Date? = nil

    // MARK: - 初始化

    init() {}

    // MARK: - 便捷计算属性（不参与持久化）

    var appearance: Appearance {
        get { Appearance(raw: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.raw }
    }

    /// 当前浏览月份的自然日视图（`currentMonthKey` 的 1 号）；未设置时返回 nil。
    var currentMonth: DateOnly? {
        get {
            guard currentMonthKey > 0 else { return nil }
            let year = Int(currentMonthKey / 100)
            let month = Int(currentMonthKey % 100)
            return DateOnly(year: year, month: month, day: 1)
        }
        set { currentMonthKey = newValue?.monthKey ?? 0 }
    }

    /// 最近使用分类的稳定读取（nil → 空数组）。
    var recentCategoryIDList: [UUID] { recentCategoryIDs ?? [] }

    /// 记录一次分类使用：去重后插到最前，最多保留 6 个（R-CAT-4 / R-IN-2）。
    func rememberCategory(_ categoryID: UUID, limit: Int = 6) {
        var list = recentCategoryIDs ?? []
        list.removeAll { $0 == categoryID }
        list.insert(categoryID, at: 0)
        if list.count > max(limit, 1) {
            list = Array(list.prefix(limit))
        }
        recentCategoryIDs = list
    }

    /// 最近一次使用的分类（只填金额时的自动选择目标）。
    var mostRecentCategoryID: UUID? { recentCategoryIDs?.first }
}
