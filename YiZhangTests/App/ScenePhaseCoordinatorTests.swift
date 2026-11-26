//
//  ScenePhaseCoordinatorTests.swift
//  YiZhangTests / App
//
//  职责：钉死「冷启动清理回收站」这条链路的**接线**（V1.1 / PRD 6.2 + 6.4-4）。
//
//  为什么这三条必须存在：
//  ① `TrashService.purgeExpired` 自己有测试（`TrashFeatureTests` 的 30 天边界），
//     但"协调器在冷启动时真的会调它"是另一件事。接线断了的表现是：
//     回收站里的过期项永远不消失，而所有服务层测试全绿——用户攒一屏"剩 0 天"的僵尸行。
//  ② 这里测的是**同步方法** `purgeExpiredIfNeeded()`，不是 `handle(.active)`：
//     后者内部是 `Task { }`，XCTest 没有确定性等待手段，写出来必然是 flaky 测试。
//     断言的行为完全相同（协调器 → `trash.purgeExpired` → 物理删除），
//     只是绕过"什么时候触发"这一层。
//
//  ⚠️ 关于"今天"：`purgeExpiredIfNeeded` 内部用 `DateOnly(Date())`
//  （生产代码刻意没留注入点——这个挂载点只关心"真实今天"）。
//  所以本文件按**真实今天**算偏移，而不是像 `TrashFeatureTests` 那样用固定日键，
//  否则用例会随日历漂移：固定 20251121 在今天之前 31 天时通过，一年后就永远不过期。
//

import SwiftData
import XCTest
@testable import YiZhang

@MainActor
final class ScenePhaseCoordinatorTests: XCTestCase {

    // MARK: - ① 过期项物理消失、未过期项保留

    func testPurgeExpiredIfNeededRemovesOnlyExpiredItems() throws {
        let environment = try makeEnvironment()
        let realToday = DateOnly(Date())
        let expiredDay = realToday.adding(days: -(TrashService.retentionDays + 1))
        let freshDay = realToday.adding(days: -(TrashService.retentionDays - 1))

        let expired = try insertEntry(in: environment, amount: 1200, occurredDay: expiredDay.key)
        let fresh = try insertEntry(in: environment, amount: 2300, occurredDay: freshDay.key)
        try markDeleted(in: environment, id: expired, at: expiredDay)
        try markDeleted(in: environment, id: fresh, at: freshDay)

        let coordinator = ScenePhaseCoordinator(environment: environment)
        coordinator.purgeExpiredIfNeeded()

        XCTAssertNil(
            try environment.writer.entry(id: expired),
            "删除日早于「今天 - \(TrashService.retentionDays) 天」的账目必须被物理删除（PRD 6.4-4）"
        )
        XCTAssertNotNil(
            try environment.writer.entry(id: fresh),
            "还没到期的账目不能被顺手清掉——用户只剩 1 天，仍然可以恢复"
        )
    }

    // MARK: - ② 活账一律不动

    func testPurgeExpiredIfNeededNeverTouchesLiveEntries() throws {
        let environment = try makeEnvironment()
        let realToday = DateOnly(Date())

        // 发生日在很久以前，但**没被删除**：这是活账，与该不该清理无关
        let live = try insertEntry(
            in: environment,
            amount: 3400,
            occurredDay: realToday.adding(days: -400).key
        )

        let coordinator = ScenePhaseCoordinator(environment: environment)
        coordinator.purgeExpiredIfNeeded()

        XCTAssertNotNil(
            try environment.writer.entry(id: live),
            "清理的判据是 `deletedDay`，不是 `occurredDay`——老老实实记了去年的账不该被删掉"
        )
        XCTAssertEqual(try environment.trash.count(), 0, "回收站本来就该是空的")
    }

    // MARK: - ③ 空环境 / 重复调用

    func testPurgeIsSafeWithoutEnvironmentAndWhenRepeated() throws {
        // 没有 environment 时必须静默返回（`AppEnvironment` 装配中途就可能收到 scenePhase）
        let detached = ScenePhaseCoordinator(environment: nil)
        detached.purgeExpiredIfNeeded()

        let environment = try makeEnvironment()
        let realToday = DateOnly(Date())
        let expiredDay = realToday.adding(days: -(TrashService.retentionDays + 5))
        let expired = try insertEntry(in: environment, amount: 4500, occurredDay: expiredDay.key)
        try markDeleted(in: environment, id: expired, at: expiredDay)

        let coordinator = ScenePhaseCoordinator(environment: environment)
        coordinator.purgeExpiredIfNeeded()
        XCTAssertNil(try environment.writer.entry(id: expired))

        // 第二次调用不能抛错，也不能"复活"或重复计数（幂等）
        coordinator.purgeExpiredIfNeeded()
        XCTAssertNil(try environment.writer.entry(id: expired))
        XCTAssertEqual(try environment.trash.count(), 0)
    }

    // MARK: - 夹具

    private func makeEnvironment() throws -> AppEnvironment {
        let container = try ModelContainerFactory.make(inMemory: true)
        return try AppEnvironment(container: container)
    }

    @discardableResult
    private func insertEntry(
        in environment: AppEnvironment,
        amount: Int64,
        occurredDay: Int32
    ) throws -> UUID {
        var draft = EntryDraft(
            typeRaw: EntryType.expense.raw,
            amount: amount,
            occurredDay: occurredDay
        )
        draft.categoryID = try environment.readContext
            .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
            .first?.id
        draft.accountID = try environment.readContext
            .fetch(QueryDescriptors.accounts(includeArchived: false))
            .first?.id

        let outcome = try environment.ledger.create(draft)
        return try XCTUnwrap(outcome.entryID, "压测夹具：账目没有落库")
    }

    /// 以"某个自然日"为删除时刻软删（`deletedDay` 由 `DeletionMark` 从时刻反算）。
    private func markDeleted(in environment: AppEnvironment, id: UUID, at day: DateOnly) throws {
        let entry = try XCTUnwrap(try environment.writer.entry(id: id))
        try environment.writer.markDeleted(entry, at: day.date)
    }
}
