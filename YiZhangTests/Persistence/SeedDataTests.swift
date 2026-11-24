//
//  SeedDataTests.swift
//  一账Tests / Persistence
//
//  验证 T05 的种子验收：首启 19 分类 / 5 账户 / 1 设置，**连跑两次数字不变**。
//  幂等是"用户第二次打开 App 不会看到两个「餐饮」"的唯一保障，所以这里必须硬断言。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SeedDataTests: XCTestCase {

    func testFirstLaunchSeedsExpectedCounts() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let result = try SeedData.seedIfNeeded(in: container)

        XCTAssertEqual(result.insertedCategories, 19)
        XCTAssertEqual(result.insertedAccounts, 5)
        XCTAssertEqual(result.insertedSettings, 1)
        XCTAssertTrue(result.didChangeAnything)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YiZhang.Category>()), 19)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 5)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 1)
        XCTAssertTrue(try SeedData.isFullySeeded(in: context))
    }

    func testRunningSeedTwiceKeepsCountsStable() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)

        _ = try SeedData.seedIfNeeded(in: container)
        let secondRun = try SeedData.seedIfNeeded(in: container)

        XCTAssertEqual(secondRun.insertedCategories, 0, "第二次运行不应再插分类")
        XCTAssertEqual(secondRun.insertedAccounts, 0, "第二次运行不应再插账户")
        XCTAssertEqual(secondRun.insertedSettings, 0, "第二次运行不应再建设置")
        XCTAssertFalse(secondRun.didChangeAnything)

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YiZhang.Category>()), 19)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 5)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 1)
    }

    func testSeedIsIdempotentEvenIfUserRenamedCategory() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        _ = try SeedData.seedIfNeeded(in: container)

        // 用户把「餐饮」改名——判重必须按 presetKey（确定性 id），不能按 name
        let context = ModelContext(container)
        let categories = try context.fetch(QueryDescriptors.categories(of: .expense))
        let food = try XCTUnwrap(categories.first { $0.name == "餐饮" })
        food.name = "吃饭"
        try context.save()

        _ = try SeedData.seedIfNeeded(in: container)

        let after = try ModelContext(container).fetch(QueryDescriptors.categories(of: .expense))
        XCTAssertEqual(after.count, 14, "改名后不应再插一条「餐饮」")
        XCTAssertTrue(after.contains { $0.name == "吃饭" })
        XCTAssertFalse(after.contains { $0.name == "餐饮" })
    }

    func testPresetCategoriesHaveColorIconAndType() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        _ = try SeedData.seedIfNeeded(in: container)

        let context = ModelContext(container)
        let all = try context.fetch(FetchDescriptor<YiZhang.Category>())
        XCTAssertEqual(all.count, 19)

        for category in all {
            XCTAssertFalse(category.name.isEmpty, "分类名不能为空")
            XCTAssertFalse(category.colorHex.isEmpty, "分类色不能为空：\(category.name)")
            XCTAssertFalse(category.iconName.isEmpty, "分类图标不能为空：\(category.name)")
            XCTAssertTrue(category.isPreset)
            XCTAssertTrue(category.canDelete == false, "预置分类不可删除")
            XCTAssertNotNil(Theme.rgbComponents(hex: category.colorHex), "颜色必须是合法 hex：\(category.colorHex)")
            XCTAssertEqual(
                PresetCatalog.sanitizedSymbolName(category.iconName),
                category.iconName,
                "种子里的图标必须在 40 个白名单内：\(category.iconName)"
            )
        }

        XCTAssertEqual(all.filter { $0.type == .expense }.count, 14)
        XCTAssertEqual(all.filter { $0.type == .income }.count, 5)
    }

    func testPresetAccountsHaveKindAndOrder() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        _ = try SeedData.seedIfNeeded(in: container)

        let context = ModelContext(container)
        let accounts = try context.fetch(QueryDescriptors.accounts())
        XCTAssertEqual(accounts.count, 5)
        XCTAssertEqual(accounts.map(\.name), ["现金", "微信", "支付宝", "储蓄卡", "信用卡"])
        XCTAssertEqual(accounts.map(\.kind), [.cash, .wechat, .alipay, .debit, .credit])
        XCTAssertTrue(accounts.allSatisfy { $0.initialBalance == 0 })
        XCTAssertTrue(accounts.allSatisfy { $0.isArchived == false })
    }

    func testSettingsRowIsUsableAndSingle() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        _ = try SeedData.seedIfNeeded(in: container)

        let context = ModelContext(container)
        let settings = try XCTUnwrap(try context.fetch(QueryDescriptors.appSettings()).first)
        XCTAssertTrue(settings.hasSeeded)
        XCTAssertEqual(settings.appearance, .system)
        // `currentMonth` 是"当月 1 号"的日期视图（月份上下文的锚点），断言月份键而不是具体日
        XCTAssertEqual(settings.currentMonth?.monthKey, DateOnly(Date()).monthKey)
        XCTAssertEqual(settings.currentMonth?.day, 1)
        XCTAssertNil(settings.defaultAccountID)
        XCTAssertEqual(settings.recentCategoryIDList, [])
    }

    func testStableIDIsDeterministicAndUnique() {
        let keys = PresetCatalog.allCategories.map(\.presetKey)
            + PresetCatalog.accounts.map(\.presetKey)
            + ["settings.singleton"]

        // 确定性：同一 key 两次得到同一个 UUID
        for key in keys {
            XCTAssertEqual(PresetCatalog.stableID(for: key), PresetCatalog.stableID(for: key))
        }

        // 唯一性：24 个 key 互不碰撞
        let ids = Set(keys.map { PresetCatalog.stableID(for: $0) })
        XCTAssertEqual(ids.count, keys.count)

        // 与随机 UUID 不同：结果是稳定的（换进程也一样），这里用"不等于全零"做最低限度自检
        XCTAssertNotEqual(PresetCatalog.stableID(for: "cat.food"), UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }
}
