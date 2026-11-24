//
//  SeedData.swift
//  一账 / Core / Persistence
//
//  职责：首启幂等种子——19 个分类 + 5 个账户 + 1 条设置。
//
//  "幂等"的定义（T05 验收）：连跑两次，库里仍然是 19 分类 / 5 账户 / 1 设置。
//
//  判重依据是 `presetKey`，不是 name：
//  用户完全可能把「餐饮」改名为「吃饭」、把「微信」改成「微信零钱」。若按 name 判重，
//  第二次启动会再插一条「餐饮」，用户就会看到两个分类——这是最典型的种子事故。
//  实现上，`presetKey` 通过 `PresetCatalog.stableID(for:)` 变成确定性 UUID，
//  所以判重就是"这个 id 在不在库里"，而且**模型不需要新增字段**（架构 §3.2 字段表不变）。
//
//  分类的 id 是确定的，这也带来一个额外好处：订阅默认分类可以在任何地方用
//  `PresetCatalog.subscriptionCategoryID` 直接引用，不需要先查库（R-CAT-4）。
//

import Foundation
import SwiftData

/// 种子写入结果（便于测试断言与日志）。
struct SeedResult: Hashable, Sendable {
    var insertedCategories: Int = 0
    var insertedAccounts: Int = 0
    var insertedSettings: Int = 0

    /// 本次是否真的写入了新数据（false 表示库里已经齐了）。
    var didChangeAnything: Bool {
        insertedCategories > 0 || insertedAccounts > 0 || insertedSettings > 0
    }
}

/// 预置数据种子。
enum SeedData {

    /// 幂等写入种子数据。App 启动时调用一次（`AppEnvironment.init`）。
    ///
    /// - Parameter container: 应用容器。
    /// - Returns: 本次实际插入了多少条。
    @discardableResult
    @MainActor
    static func seedIfNeeded(in container: ModelContainer) throws -> SeedResult {
        try seedIfNeeded(in: ModelContext(container))
    }

    /// 幂等写入种子数据（可注入 context，供测试使用）。
    ///
    /// - Parameter context: 目标上下文（本方法自己 `save()`，一次提交）。
    @discardableResult
    @MainActor
    static func seedIfNeeded(in context: ModelContext) throws -> SeedResult {
        var result = SeedResult()

        // 1. 分类：按确定性 id 判重（19 条）
        let existingCategoryIDs = Set(try context.fetch(QueryDescriptors.categories(of: .expense)).map(\.id))
            .union(try context.fetch(QueryDescriptors.categories(of: .income)).map(\.id))

        for preset in PresetCatalog.allCategories {
            let stableID = PresetCatalog.stableID(for: preset.presetKey)
            guard !existingCategoryIDs.contains(stableID) else { continue }

            let category = Category()
            category.id = stableID
            category.name = preset.name
            category.type = preset.type
            category.iconName = preset.iconName
            category.colorHex = preset.colorHex
            category.isPreset = true
            category.isHidden = false
            category.sortOrder = preset.sortOrder
            category.createdAt = Date()
            category.updatedAt = category.createdAt
            context.insert(category)
            result.insertedCategories += 1
        }

        // 2. 账户：同样按确定性 id 判重（5 条）
        let existingAccountIDs = Set(try context.fetch(QueryDescriptors.accounts()).map(\.id))

        for preset in PresetCatalog.accounts {
            let stableID = PresetCatalog.stableID(for: preset.presetKey)
            guard !existingAccountIDs.contains(stableID) else { continue }

            let account = Account()
            account.id = stableID
            account.name = preset.name
            account.kind = preset.kind
            account.initialBalance = 0
            account.isArchived = false
            account.sortOrder = preset.sortOrder
            account.createdAt = Date()
            account.updatedAt = account.createdAt
            context.insert(account)
            result.insertedAccounts += 1
        }

        // 3. 设置：只允许一条（不加唯一约束，见架构 §3.7 D3——单例由本方法保证）
        let existingSettings = try context.fetch(QueryDescriptors.appSettings())
        if existingSettings.isEmpty {
            let settings = AppSettings()
            settings.id = PresetCatalog.stableID(for: "settings.singleton")
            settings.currentMonth = DateOnly(Date())
            settings.subscriptionReminderEnabled = true
            settings.todoReminderEnabled = true
            settings.appearance = .system
            settings.hasSeeded = true
            settings.recentCategoryIDs = []
            context.insert(settings)
            result.insertedSettings = 1
        } else if existingSettings.count == 1, existingSettings[0].hasSeeded == false {
            // 老数据/异常数据：标记已播种，避免每次启动都走插入分支
            existingSettings[0].hasSeeded = true
        }

        if result.didChangeAnything || existingSettings.first?.hasSeeded == true {
            try context.save()
        }
        return result
    }

    /// 库里的种子是否已完整（分类 19 / 账户 5 / 设置 1）。
    ///
    /// 用途：自检与 UI 冒烟；不参与启动流程判断（启动只关心"要不要写"）。
    @MainActor
    static func isFullySeeded(in context: ModelContext) throws -> Bool {
        let categoryCount = try context.fetchCount(QueryDescriptors.categories(of: .expense))
            + context.fetchCount(QueryDescriptors.categories(of: .income))
        let accountCount = try context.fetchCount(QueryDescriptors.accounts())
        let settingsCount = try context.fetchCount(QueryDescriptors.appSettings())
        return categoryCount == PresetCatalog.categoryCount
            && accountCount == PresetCatalog.accountCount
            && settingsCount == 1
    }
}
