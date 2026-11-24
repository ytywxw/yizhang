//
//  AppEnvironmentTests.swift
//  一账Tests / App
//
//  T01 的验收标准里有两条只能在运行时验证：
//  ① 依赖装配成功（容器 + 服务 + 设置都在）；
//  ② 写入后 `dataVersion` 会变（这是统计页等"手动刷新"页面唯一的失效信号）。
//  这两条如果不用测试固定住，接线一旦写错（比如忘了把 `onDidCommit` 接上），
//  表现是"统计页数字永远不更新"，而它不会崩溃、不会报错，只会悄悄错。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class AppEnvironmentTests: XCTestCase {

    func testInitSeedsAndLoadsEverything() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        XCTAssertEqual(environment.dataVersion, 0)
        XCTAssertTrue(environment.settings.hasSeeded)
        XCTAssertNotNil(environment.ledger.onDidCommit, "写入回调必须接上，否则 dataVersion 永不推进")

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YiZhang.Category>()), 19)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 5)
    }

    func testBumpDataVersionIncrements() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        environment.bumpDataVersion()
        XCTAssertEqual(environment.dataVersion, 1)
        environment.bumpDataVersion()
        XCTAssertEqual(environment.dataVersion, 2)
    }

    func testLedgerWriteBumpsDataVersion() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        let writer = LedgerWriter(container: container)
        let categories = try writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try writer.fetch(QueryDescriptors.accounts())
        var draft = EntryDraft(amount: 1200, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try XCTUnwrap(categories.first?.id)
        draft.accountID = try XCTUnwrap(accounts.first?.id)
        // 用带幂等键的来源（待办），才能验证"重复命中不广播"
        draft.sourceRaw = EntrySource.todo.raw
        draft.sourceRefID = UUID()

        XCTAssertEqual(environment.dataVersion, 0)
        try environment.ledger.create(draft)
        XCTAssertEqual(environment.dataVersion, 1, "写入提交后必须广播")

        // 幂等命中不广播（重复扫描不该让统计页反复重算）
        let duplicateOutcome = try environment.ledger.create(draft)
        XCTAssertFalse(duplicateOutcome.wasInserted)
        XCTAssertEqual(environment.dataVersion, 1)
    }

    func testDeleteAndUndoBumpDataVersion() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        let writer = LedgerWriter(container: container)
        let categories = try writer.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try writer.fetch(QueryDescriptors.accounts())
        var draft = EntryDraft(amount: 1200, occurredDay: DateOnly(Date()).key)
        draft.categoryID = try XCTUnwrap(categories.first?.id)
        draft.accountID = try XCTUnwrap(accounts.first?.id)

        let entryID = try XCTUnwrap(try environment.ledger.create(draft).entryID)
        let afterCreate = environment.dataVersion

        let deletedToken = await environment.ledger.delete(id: entryID)
        let token = try XCTUnwrap(deletedToken)
        XCTAssertEqual(environment.dataVersion, afterCreate + 1)

        XCTAssertTrue(environment.ledger.undoDelete(token))
        XCTAssertEqual(environment.dataVersion, afterCreate + 2)
    }

    func testSceneCoordinatorIsAttached() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        // 骨架阶段只能验证"调用不崩、可重复调用"；T11/T23 接线后这里会补真实断言
        environment.sceneCoordinator.handle(.active)
        environment.sceneCoordinator.handle(.background)
        await environment.sceneCoordinator.sweepIfNeeded()
        await environment.sceneCoordinator.runDiagnosticsIfNeeded()
    }

    func testSaveSettingsPersistsFlags() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        environment.settings.subscriptionReminderEnabled = false
        environment.settings.appearance = .dark
        environment.saveSettings()

        let context = ModelContext(container)
        let reloaded = try XCTUnwrap(try context.fetch(QueryDescriptors.appSettings()).first)
        XCTAssertFalse(reloaded.subscriptionReminderEnabled)
        XCTAssertEqual(reloaded.appearance, .dark)
    }
}
