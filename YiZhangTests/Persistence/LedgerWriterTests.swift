//
//  LedgerWriterTests.swift
//  一账Tests / Persistence
//
//  验证 T05 的幂等与软删三条硬要求：
//  ① 插入返回 `.inserted`；
//  ② 同 `uniqueKey` 再插返回 `.skippedDuplicate` 且账目数不变；
//  ③ **同一批次连续插两次同 key 也只落 1 条**（`includePendingChanges` 的关键验证）；
//  ④ 软删后 `restore` 字段完整恢复；`hardDelete` 后不可恢复。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class LedgerWriterTests: XCTestCase {

    // MARK: - 插入与幂等

    func testInsertReturnsInsertedID() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let outcome = try writer.insert(EntryDraft(amount: 1200, occurredDay: 20251120))

        guard case .inserted(let id) = outcome else {
            return XCTFail("首次插入应返回 .inserted，实际是 \(outcome)")
        }
        XCTAssertNotNil(try writer.entry(id: id))
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 1)
    }

    func testDuplicateUniqueKeyIsSkipped() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let subscriptionID = UUID()
        var draft = EntryDraft(amount: 2500, occurredDay: 20251125)
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = subscriptionID
        draft.sourceCycleKey = "2025-11"
        draft.uniqueKey = SubscriptionSnapshot.makeUniqueKey(
            subscriptionID: subscriptionID,
            cycleKey: "2025-11"
        )

        let first = try writer.insert(draft)
        XCTAssertTrue(first.wasInserted)

        let second = try writer.insert(draft)
        XCTAssertEqual(second, .skippedDuplicate(draft.uniqueKey ?? ""))
        XCTAssertFalse(second.wasInserted)

        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 1, "重复幂等键不得产生第二条账目")
    }

    func testSameBatchTwiceInsertsOnlyOnce() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        var draft = EntryDraft(amount: 990, occurredDay: 20251120)
        draft.sourceRaw = EntrySource.todo.raw
        draft.sourceRefID = UUID()
        draft.uniqueKey = "todo|\(draft.sourceRefID?.uuidString ?? "")"

        // 两次都不 save：验证"未提交的插入"也能被幂等检查看到（includePendingChanges）
        let first = try writer.insert(draft, save: false)
        let second = try writer.insert(draft, save: false)

        XCTAssertTrue(first.wasInserted)
        XCTAssertEqual(second, .skippedDuplicate(draft.uniqueKey ?? ""))
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 1, "pending change 也算重复")

        try writer.save()
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 1)
    }

    func testNilUniqueKeyNeverDeduplicated() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let draft = EntryDraft(amount: 100, occurredDay: 20251120)
        XCTAssertTrue(try writer.insert(draft).wasInserted)
        XCTAssertTrue(try writer.insert(draft).wasInserted)
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 2, "手动记账没有幂等键，允许同额同日多笔")
    }

    // MARK: - 软删与撤销

    func testSoftDeleteThenRestoreRestoresEveryField() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let category = Category()
        category.name = "餐饮"
        category.colorHex = "#C0392B"
        let account = Account()
        account.name = "现金"
        writer.modelContext.insert(category)
        writer.modelContext.insert(account)
        try writer.save()

        let subscriptionID = UUID()
        var draft = EntryDraft(amount: 2800, occurredDay: 20251120)
        draft.categoryID = category.id
        draft.accountID = account.id
        draft.note = "订阅：视频会员"
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = subscriptionID
        draft.sourceCycleKey = "2025-11"
        draft.uniqueKey = SubscriptionSnapshot.makeUniqueKey(subscriptionID: subscriptionID, cycleKey: "2025-11")

        let outcome = try writer.insert(draft)
        let entryID = try XCTUnwrap(outcome.entryID)
        let before = try XCTUnwrap(try writer.entry(id: entryID))
        let snapshotBefore = LedgerEntrySnapshot(entry: before)

        let deletedSnapshot = try XCTUnwrap(try writer.softDelete(id: entryID))
        // 返回的是"删除前"的快照（deletedAt 为 nil），撤销时正是靠它整体写回
        XCTAssertNil(deletedSnapshot.deletedAt)
        XCTAssertEqual(deletedSnapshot.amount, snapshotBefore.amount)

        let afterDelete = try XCTUnwrap(try writer.entry(id: entryID))
        XCTAssertTrue(afterDelete.isDeleted)
        XCTAssertNotNil(afterDelete.deletedAt)

        // 软删只改 deletedAt/updatedAt，其余字段一字不动
        XCTAssertEqual(afterDelete.amount, snapshotBefore.amount)
        XCTAssertEqual(afterDelete.sourceCycleKey, "2025-11")
        XCTAssertEqual(afterDelete.sourceCycleUniqueKey, snapshotBefore.sourceCycleUniqueKey)

        // 恢复
        XCTAssertTrue(try writer.restore(deletedSnapshot))

        let restored = try XCTUnwrap(try writer.entry(id: entryID))
        XCTAssertFalse(restored.isDeleted)
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.amount, 2800)
        XCTAssertEqual(restored.note, "订阅：视频会员")
        XCTAssertEqual(restored.occurredDay, 20251120)
        XCTAssertEqual(restored.sourceRaw, EntrySource.subscription.raw)
        XCTAssertEqual(restored.sourceRefID, subscriptionID)
        XCTAssertEqual(restored.sourceCycleKey, "2025-11")
        XCTAssertEqual(restored.sourceCycleUniqueKey, snapshotBefore.sourceCycleUniqueKey)
        XCTAssertEqual(restored.category?.id, category.id, "关系也要恢复")
        XCTAssertEqual(restored.account?.id, account.id)
        XCTAssertEqual(restored.createdAt, snapshotBefore.createdAt)
    }

    func testHardDeleteRemovesEntryAndCannotBeRestored() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let outcome = try writer.insert(EntryDraft(amount: 500, occurredDay: 20251120))
        let entryID = try XCTUnwrap(outcome.entryID)
        let snapshot = LedgerEntrySnapshot(entry: try XCTUnwrap(try writer.entry(id: entryID)))

        XCTAssertTrue(try writer.hardDelete(id: entryID))
        XCTAssertNil(try writer.entry(id: entryID))
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 0)

        XCTAssertFalse(try writer.restore(snapshot), "硬删后恢复应返回 false，而不是抛错")
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 0)
    }

    func testHardDeletedUniqueKeyCanBeRegenerated() async throws {
        // R8 的行为验证：B 分支用硬删，同一幂等键才允许重新生成
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let subscriptionID = UUID()
        var draft = EntryDraft(amount: 2500, occurredDay: 20251125)
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = subscriptionID
        draft.uniqueKey = SubscriptionSnapshot.makeUniqueKey(subscriptionID: subscriptionID, cycleKey: "2025-11")

        let entryID = try XCTUnwrap(try writer.insert(draft).entryID)
        _ = try writer.softDelete(id: entryID)
        XCTAssertEqual(
            try writer.insert(draft),
            .skippedDuplicate(draft.uniqueKey ?? ""),
            "软删记录仍占用幂等键（R-SUB-7 含软删记录）"
        )

        _ = try writer.hardDelete(id: entryID)
        XCTAssertTrue(try writer.insert(draft).wasInserted, "硬删后该周期可以重新生成")
        XCTAssertEqual(try writer.count(QueryDescriptors.allEntries()), 1)
    }

    // MARK: - 更新

    func testUpdateWritesUpdatedAtAndKeepsID() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let entryID = try XCTUnwrap(try writer.insert(EntryDraft(amount: 100, occurredDay: 20251120)).entryID)
        let before = try XCTUnwrap(try writer.entry(id: entryID))

        let snapshot = try XCTUnwrap(
            try writer.update(id: entryID) { entry in
                entry.amount = 300
                entry.note = "改了金额"
            }
        )

        XCTAssertEqual(snapshot.id, entryID)
        XCTAssertEqual(snapshot.amount, 300)
        XCTAssertEqual(snapshot.note, "改了金额")
        XCTAssertEqual(try writer.entry(id: entryID)?.amount, 300)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(try writer.entry(id: entryID)).updatedAt,
            before.updatedAt
        )
    }
}
