//
//  PresetCatalog.swift
//  一账 / Core / Resources
//
//  职责：全部预置数据的唯一来源——19 个分类、5 个账户、40 个精选 SF Symbols、12 色品牌色板。
//
//  为什么是"纯数据"而不是"种子的实现"：本文件只描述"应该有什么"，`SeedData` 负责"怎么落地"，
//  `Theme` 负责"怎么渲染"。三者分离后，调整一个分类颜色不需要碰任何持久化代码。
//
//  `presetKey` 是预置项的身份，**不落库**（模型没有这个字段，保持架构 §3.2 的字段表不变、
//  也不给 CloudKit 增加迁移面）。身份通过 `stableID(for:)` 变成确定性 UUID：
//  "种子判重"等价于"按 presetKey 判重"，因为同一个 key 永远映射到同一个 UUID。
//  这也让"用户改名/改色后再跑种子"不会重复插入——判重依据不是 name。
//

import Foundation

/// 预置数据目录（纯值类型，无 SwiftData / SwiftUI 依赖）。
enum PresetCatalog {

    // MARK: - 预置分类

    /// 一个预置分类。
    struct CategoryPreset: Hashable, Sendable {
        /// 稳定身份，如 `"cat.food"`。不落库，用于生成确定性 UUID 与判重。
        let presetKey: String
        let name: String
        /// 与账目类型强绑（R-CAT：支出分类不能用于收入账目）。
        let type: EntryType
        let iconName: String
        /// 取自 `brandColors` 的浅色模式 hex。
        let colorHex: String
        let sortOrder: Int
    }

    // MARK: - 预置账户

    /// 一个预置账户。
    struct AccountPreset: Hashable, Sendable {
        let presetKey: String
        let name: String
        let kind: AccountKind
        let sortOrder: Int
    }

    // MARK: - 品牌色板

    /// 一个品牌色。每个色都有浅色 / 深色两套 hex：
    /// 深色模式下同一色相必须提亮，否则在 #1C1C1E 背景上对比度不足（验收要求 ≥3:1）。
    struct BrandColor: Hashable, Sendable {
        let key: String
        let displayName: String
        let lightHex: String
        let darkHex: String
    }

    /// 12 色品牌色板。
    ///
    /// 对比度实测（`ThemeTests` 会断言，不是"感觉够亮"）：
    /// 浅色 hex 对 #FFFFFF 最低 4.24:1（orange），深色 hex 对 #1C1C1E 最低 6.67:1（indigo）。
    static let brandColors: [BrandColor] = [
        BrandColor(key: "red", displayName: "珊瑚红", lightHex: "#C0392B", darkHex: "#FF7B6B"),
        BrandColor(key: "orange", displayName: "琥珀橙", lightHex: "#B26A00", darkHex: "#FFA94D"),
        BrandColor(key: "gold", displayName: "麦穗黄", lightHex: "#8A6D00", darkHex: "#E8C547"),
        BrandColor(key: "green", displayName: "苔原绿", lightHex: "#2E7D32", darkHex: "#6ED47A"),
        BrandColor(key: "teal", displayName: "湖水青", lightHex: "#00796B", darkHex: "#4FD1C5"),
        BrandColor(key: "blue", displayName: "远山蓝", lightHex: "#1565C0", darkHex: "#64A9F5"),
        BrandColor(key: "indigo", displayName: "暮色靛", lightHex: "#3F51B5", darkHex: "#8B9BFF"),
        BrandColor(key: "purple", displayName: "鸢尾紫", lightHex: "#6A1B9A", darkHex: "#C08BFF"),
        BrandColor(key: "pink", displayName: "胭脂粉", lightHex: "#AD1457", darkHex: "#FF8FB3"),
        BrandColor(key: "brown", displayName: "可可棕", lightHex: "#6D4C41", darkHex: "#C9A186"),
        BrandColor(key: "gray", displayName: "石墨灰", lightHex: "#5F6368", darkHex: "#A8ADB4"),
        BrandColor(key: "lime", displayName: "莳萝绿", lightHex: "#4C6B00", darkHex: "#B6D96B")
    ]

    /// 取色板中第 index 个颜色（循环取用，供分类按顺序分配）。
    static func paletteHex(at index: Int, dark: Bool = false) -> String {
        let count = brandColors.count
        guard count > 0 else { return dark ? "#A8ADB4" : "#5F6368" }
        let normalized = ((index % count) + count) % count
        let color = brandColors[normalized]
        return dark ? color.darkHex : color.lightHex
    }

    /// 按 key 取色，如 `paletteHex(key: "green")`。
    static func paletteHex(key: String) -> String? {
        brandColors.first { $0.key == key }?.lightHex
    }

    /// 兜底色（"其他"类目与未知 hex）。
    static let fallbackColorHex = "#5F6368"

    // MARK: - 预置分类（支出 14 + 收入 5）

    /// 支出预置分类（PRD 3.2.3 的 14 个，顺序即 sortOrder）。
    static let expenseCategories: [CategoryPreset] = [
        CategoryPreset(presetKey: "cat.food", name: "餐饮", type: .expense,
                       iconName: "fork.knife", colorHex: paletteHex(at: 0), sortOrder: 0),
        CategoryPreset(presetKey: "cat.grocery", name: "买菜生鲜", type: .expense,
                       iconName: "cart", colorHex: paletteHex(at: 3), sortOrder: 1),
        CategoryPreset(presetKey: "cat.transport", name: "交通出行", type: .expense,
                       iconName: "tram", colorHex: paletteHex(at: 5), sortOrder: 2),
        CategoryPreset(presetKey: "cat.shopping", name: "购物", type: .expense,
                       iconName: "bag", colorHex: paletteHex(at: 8), sortOrder: 3),
        CategoryPreset(presetKey: "cat.housing", name: "居住", type: .expense,
                       iconName: "house", colorHex: paletteHex(at: 9), sortOrder: 4),
        CategoryPreset(presetKey: "cat.telecom", name: "通讯网络", type: .expense,
                       iconName: "wifi", colorHex: paletteHex(at: 4), sortOrder: 5),
        CategoryPreset(presetKey: "cat.entertainment", name: "娱乐", type: .expense,
                       iconName: "gamecontroller", colorHex: paletteHex(at: 7), sortOrder: 6),
        CategoryPreset(presetKey: "cat.medical", name: "医疗健康", type: .expense,
                       iconName: "cross.case", colorHex: paletteHex(at: 0), sortOrder: 7),
        CategoryPreset(presetKey: "cat.education", name: "教育学习", type: .expense,
                       iconName: "book", colorHex: paletteHex(at: 6), sortOrder: 8),
        CategoryPreset(presetKey: "cat.social", name: "人情往来", type: .expense,
                       iconName: "gift", colorHex: paletteHex(at: 8), sortOrder: 9),
        CategoryPreset(presetKey: "cat.travel", name: "旅行", type: .expense,
                       iconName: "airplane", colorHex: paletteHex(at: 2), sortOrder: 10),
        CategoryPreset(presetKey: "cat.pet", name: "宠物", type: .expense,
                       iconName: "pawprint", colorHex: paletteHex(at: 1), sortOrder: 11),
        // 「订阅服务」必须是第 13 个：R-CAT-4 要求新建订阅默认分类为它，UI 也靠这个 key 找它
        CategoryPreset(presetKey: "cat.subscription", name: "订阅服务", type: .expense,
                       iconName: "arrow.triangle.2.circlepath", colorHex: paletteHex(at: 4), sortOrder: 12),
        CategoryPreset(presetKey: "cat.other_expense", name: "其他", type: .expense,
                       iconName: "ellipsis.circle", colorHex: fallbackColorHex, sortOrder: 13)
    ]

    /// 收入预置分类（5 个）。
    static let incomeCategories: [CategoryPreset] = [
        CategoryPreset(presetKey: "cat.salary", name: "工资", type: .income,
                       iconName: "banknote", colorHex: paletteHex(at: 3), sortOrder: 0),
        CategoryPreset(presetKey: "cat.bonus", name: "奖金", type: .income,
                       iconName: "star", colorHex: paletteHex(at: 2), sortOrder: 1),
        CategoryPreset(presetKey: "cat.side_job", name: "兼职副业", type: .income,
                       iconName: "briefcase", colorHex: paletteHex(at: 5), sortOrder: 2),
        CategoryPreset(presetKey: "cat.investment", name: "投资收益", type: .income,
                       iconName: "chart.line.uptrend.xyaxis", colorHex: paletteHex(at: 10), sortOrder: 3),
        CategoryPreset(presetKey: "cat.other_income", name: "其他收入", type: .income,
                       iconName: "plus.circle", colorHex: fallbackColorHex, sortOrder: 4)
    ]

    /// 全部预置分类（14 + 5 = 19）。
    static var allCategories: [CategoryPreset] { expenseCategories + incomeCategories }

    /// 预置分类总数，测试与种子自检用（19）。
    static var categoryCount: Int { allCategories.count }

    /// 「订阅服务」分类的稳定 id（R-CAT-4：新建订阅默认分类）。
    static var subscriptionCategoryID: UUID { stableID(for: "cat.subscription") }

    /// 「其他（支出）」分类的稳定 id（R-CAT-2：删分类时归入这里）。
    static var otherExpenseCategoryID: UUID { stableID(for: "cat.other_expense") }

    // 注：PRD 3.2.1 提到「转账类型的账目无分类，用系统内置『转账』占位」。
    // 本批**不种第 20 个占位分类**（验收口径是 19 分类），转账账目的 `category` 保持 nil，
    // 由 `Diagnostics` 在孤儿分类检查里按 `type == transfer` 排除。
    // 详见交接报告「设计疑问」第 1 条。

    // MARK: - 预置账户（5 个）

    /// 5 个预置账户（R-ACC-2）。
    static let accounts: [AccountPreset] = [
        AccountPreset(presetKey: "acc.cash", name: "现金", kind: .cash, sortOrder: 0),
        AccountPreset(presetKey: "acc.wechat", name: "微信", kind: .wechat, sortOrder: 1),
        AccountPreset(presetKey: "acc.alipay", name: "支付宝", kind: .alipay, sortOrder: 2),
        AccountPreset(presetKey: "acc.debit", name: "储蓄卡", kind: .debit, sortOrder: 3),
        AccountPreset(presetKey: "acc.credit", name: "信用卡", kind: .credit, sortOrder: 4)
    ]

    static var accountCount: Int { accounts.count }

    // MARK: - 40 个精选图标

    /// 分类可选的 SF Symbols 白名单（全部 iOS 17 可用，避免符号缺失渲染空白）。
    static let symbolNames: [String] = [
        "fork.knife", "cart", "tram", "bag", "house",
        "wifi", "gamecontroller", "cross.case", "book", "gift",
        "airplane", "pawprint", "arrow.triangle.2.circlepath", "ellipsis.circle", "banknote",
        "star", "briefcase", "chart.line.uptrend.xyaxis", "plus.circle", "cup.and.saucer",
        "car", "bus", "fuelpump", "bicycle", "creditcard",
        "wallet.pass", "smartphone", "tv", "music.note", "film",
        "dumbbell", "heart", "pills", "graduationcap", "pencil",
        "scissors", "wrench.and.screwdriver", "lightbulb", "umbrella", "leaf"
    ]

    /// 图标兜底：不在白名单里的名字一律退回 `ellipsis.circle`，
    /// 避免"用户填了一个不存在的符号 → 渲染成空白"。
    static func sanitizedSymbolName(_ candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ellipsis.circle" }
        return symbolNames.contains(trimmed) ? trimmed : "ellipsis.circle"
    }

    // MARK: - 确定性身份

    /// `presetKey` → 稳定 UUID。
    ///
    /// 实现：FNV-1a 双通道 64 位散列填满 128 位，再写入 UUID v4 的版本/变体位。
    /// 纯整数运算、无 CryptoKit 依赖、跨进程/跨设备结果一致，
    /// 因此 `SeedData` 判重 = "这个 presetKey 的 id 是否已存在"，
    /// 且**不需要在模型上加 presetKey 字段**（保持架构 §3.2 字段表与 CloudKit 迁移面不变）。
    static func stableID(for presetKey: String) -> UUID {
        var laneA: UInt64 = 0xcbf2_9ce4_8422_2325      // FNV-1a 64 offset basis
        var laneB: UInt64 = 0x9e37_79b9_7f4a_7c15      // 黄金分割常量，与 laneA 去相关
        for byte in presetKey.utf8 {
            laneA = (laneA ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            laneB = (laneB &+ UInt64(byte)) &* 0x0000_0100_0000_01b3
            laneB ^= laneB >> 29                        // 额外混合，避免低字节分布集中
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: laneA >> UInt64(56 - index * 8))
            bytes[8 + index] = UInt8(truncatingIfNeeded: laneB >> UInt64(56 - index * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40             // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80             // RFC 4122 variant

        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { destination in
            for index in 0..<16 {
                destination[index] = bytes[index]
            }
        }
        return UUID(uuid: raw)
    }
}
