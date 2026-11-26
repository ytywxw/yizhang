//
//  SchemaV2Tests.swift
//  一账Tests / Persistence
//
//  覆盖 V1.1 / T1（数据与持久化地基）的九条验收：
//  ① `SchemaV2` 是 7 模型 / 2.0.0，迁移链是 `[V1, V2]` 且 `stages` 为空（隐式轻量迁移）；
//  ② 新账目的 `confirmRaw` / `deletedDay` 落在字面量默认值上（历史数据升级后全部"已确认"）；
//  ③ `markDeleted` 同写两列、`unmarkDeleted` 同清两列（风险 R1 的核心不变量）；
//  ④ `TrashService` 按删除日倒序分组、剩余天数按自然日算；
//  ⑤ `purgeExpired` 只清"超过 30 个自然日"的那些，30 天整不过期；
//  ⑥ `restore` 清标记 + 回退订阅抑制表，且 `confirmRaw` / `createdAt` / 幂等键一字不动；
//  ⑦ `TemplateService` 第 21 个抛 `.limitReached`、名字校验、`reorder` 稳定排序、`makeFrom` 复制；
//  ⑧ 模板与账目零引用：删模板不动任何账目；
//  ⑨ `TrashService.purgeAll` 是物理删除。
//
//  为什么这些用例都建真容器：软删两列的不变量、`#Predicate` 的整数谓词、关系双向挂载
//  都无法在纯 struct 上验证——它们恰好是本批最容易做错的地方（R1 / R4）。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SchemaV2Tests: XCTestCase {

    /// 固定"今天"：2025-11-21。
    private let today = DateOnly(key: 20251121)

    // MARK: - ① SchemaV2

    func testSchemaV2DeclaresSevenModelsAndVersionTwo() throws {
        XCTAssertEqual(SchemaV2.models.count, 7)
        XCTAssertEqual(SchemaV2.versionIdentifier, Schema.Version(2, 0, 0))

        // 第 7 个模型必须是 `EntryTemplate`（V1.1 唯一的新实体）
        let names = SchemaV2.models.map { String(describing: $0) }
        XCTAssertTrue(names.contains("EntryTemplate"), "SchemaV2 必须包含 EntryTemplate，实际：\(names)")

        // V1 原样保留 6 模型 / 1.0.0（历史快照不动，见架构 R4）
        XCTAssertEqual(SchemaV1.models.count, 6)
        XCTAssertEqual(SchemaV1.versionIdentifier, Schema.Version(1, 0, 0))

        // 迁移计划：两段 schema + 空 `stages`（隐式轻量迁移）。
        // 为什么不是显式 `.lightweight(fromVersion:toVersion:)`：两版引用同一批当前 `@Model` 类，
        // `Category.templates` / `Account.templates` 的 `inverse:` 会把 `EntryTemplate` 拉进
        // V1 的 CoreData 模型，导致 'Duplicate version checksums detected.' 崩溃。
        // 探针矩阵与报错原文见 `YiZhang/Core/Persistence/SchemaV1.swift` 文件头。
        XCTAssertEqual(YiZhangMigrationPlan.schemas.count, 2)
        XCTAssertTrue(YiZhangMigrationPlan.stages.isEmpty)
    }

    func testContainerBootsOnSchemaV2WithMigrationPlan() throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        // 新实体表存在且为空（说明 V2 的 schema 真的建起来了）
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EntryTemplate>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
    }

    // MARK: - ② 新字段默认值

    func testNewEntryDefaultsToConfirmedAndNotDeleted() throws {
        let world = try makeWorld()
        let entry = try world.insertEntry(amount: 2800, occurredDay: 20251120)

        let stored = try XCTUnwrap(try world.writer.entry(id: entry))
        XCTAssertEqual(stored.confirmRaw, "confirmed")
        XCTAssertEqual(stored.confirmation, EntryConfirmation.confirmed)
        XCTAssertFalse(stored.isPending)
        XCTAssertEqual(stored.deletedDay, 0)
        XCTAssertNil(stored.deletedAt)
        XCTAssertNil(stored.deletedDate)
        XCTAssertTrue(stored.isActive)
    }

    func testEntryCanBeInsertedAsPending() throws {
        let world = try makeWorld()
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: 2500, occurredDay: 20251115)
        draft.confirmRaw = EntryConfirmation.pending.raw
        let id = try XCTUnwrap(try world.writer.insert(draft).entryID)

        let stored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertTrue(stored.isPending)
        XCTAssertEqual(stored.confirmation, EntryConfirmation.pending)
        // 待确认不影响"是否计入"的任何口径
        XCTAssertTrue(stored.isActive)
    }

    // MARK: - ③ 软删除的两个唯一入口

    func testMarkDeletedWritesBothColumns() throws {
        let world = try makeWorld()
        let id = try world.insertEntry(amount: 1200, occurredDay: 20251101)
        let moment = DateOnly(key: 20251118).date

        let entry = try XCTUnwrap(try world.writer.entry(id: id))
        try world.writer.markDeleted(entry, at: moment)

        let stored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertNotNil(stored.deletedAt)
        XCTAssertEqual(stored.deletedDay, 20251118, "deletedDay 必须与删除时刻指向同一个自然日")
        XCTAssertEqual(stored.deletedDate, DateOnly(key: 20251118))
        XCTAssertTrue(stored.isDeleted)
        XCTAssertFalse(stored.isActive)
        XCTAssertEqual(stored.updatedAt, moment, "软删也要刷新 updatedAt")
    }

    func testUnmarkDeletedClearsBothColumns() throws {
        let world = try makeWorld()
        let id = try world.insertEntry(amount: 1200, occurredDay: 20251101)
        let entry = try XCTUnwrap(try world.writer.entry(id: id))
        try world.writer.markDeleted(entry, at: DateOnly(key: 20251118).date)

        let deleted = try XCTUnwrap(try world.writer.entry(id: id))
        try world.writer.unmarkDeleted(deleted, at: DateOnly(key: 20251120).date)

        let restored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.deletedDay, 0, "风险 R1：只清 deletedAt 不清 deletedDay 会让记录同时出现在账本和回收站")
        XCTAssertTrue(restored.isActive)
    }

    func testSoftDeleteThenRestoreSnapshotKeepsDeletionConsistent() throws {
        let world = try makeWorld()
        let id = try world.insertEntry(amount: 1200, occurredDay: 20251101)

        // `softDelete` 返回的是**删除前**的快照（V1.0 既有契约，见 `LedgerWriterTests`）：
        // 它是撤销用的"整体写回凭据"，所以此刻两列都该是空的。
        let snapshot = try XCTUnwrap(try world.writer.softDelete(id: id, at: DateOnly(key: 20251118).date))
        XCTAssertNil(snapshot.deletedAt, "撤销凭据记的是删除前的状态")
        XCTAssertEqual(snapshot.deletedDay, 0)
        XCTAssertEqual(snapshot.amount, 1200, "软删不动业务字段")

        // 落盘侧：两列同进（R1 的正向）
        let deleted = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertEqual(deleted.deletedDay, 20251118)
        XCTAssertNotNil(deleted.deletedAt)

        // 用"删除前快照"恢复 → 回到活账，两列同清（R1 的反向）
        XCTAssertTrue(try world.writer.restore(snapshot))
        let restored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.deletedDay, 0, "deletedDay 不清会让它同时出现在账本和回收站")

        // 再补一条反向路径：把"已删除态"的快照喂给 `restore`，账目应重新变成已删除，
        // 且 `deletedDay` 与 `deletedAt` 一起回来（这条分支专门防"只写回一列"）。
        try world.writer.markDeleted(restored, at: DateOnly(key: 20251119).date)
        let markedSnapshot = LedgerEntrySnapshot(entry: try XCTUnwrap(try world.writer.entry(id: id)))
        XCTAssertEqual(markedSnapshot.deletedDay, 20251119)
        try world.writer.unmarkDeleted(try XCTUnwrap(try world.writer.entry(id: id)))
        XCTAssertTrue(try world.writer.restore(markedSnapshot))

        let deletedAgain = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertEqual(deletedAgain.deletedDay, 20251119)
        XCTAssertNotNil(deletedAgain.deletedAt)
        XCTAssertFalse(deletedAgain.isActive)
    }

    // MARK: - ④ 回收站分组

    func testTrashGroupsByDeletedDayDescending() throws {
        let world = try makeWorld()
        let olderID = try world.insertEntry(amount: 1200, occurredDay: 20251101)
        let newerOneID = try world.insertEntry(amount: 3000, occurredDay: 20251110)
        let newerTwoID = try world.insertEntry(amount: 500, occurredDay: 20251112)

        try world.markDeleted(olderID, atDay: 20251105)
        try world.markDeleted(newerOneID, atDay: 20251109)
        try world.markDeleted(newerTwoID, atDay: 20251109)

        XCTAssertEqual(try world.trash.count(), 3)

        let groups = try world.trash.groups(today: today)
        XCTAssertEqual(groups.count, 2, "两个不同的删除日 → 两组")
        XCTAssertEqual(groups[0].day, 20251109, "删除日倒序：较新的一组在前")
        XCTAssertEqual(groups[1].day, 20251105)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[1].count, 1)

        // 剩余天数按自然日算：11-09 距今 12 天 → 剩 18 天
        let item = try XCTUnwrap(groups[0].items.first)
        XCTAssertEqual(item.remainingDays, 18)
        XCTAssertEqual(item.deletedDate, DateOnly(key: 20251109))
        XCTAssertEqual(Set(groups[0].items.map(\.occurredDay)), [20251110, 20251112])
        XCTAssertEqual(item.sourceRaw, EntrySource.manual.raw)
        XCTAssertFalse(item.isPending)
        XCTAssertFalse(item.isExpiringSoon)
    }

    func testTrashGroupsExcludesLiveEntries() throws {
        let world = try makeWorld()
        let deletedID = try world.insertEntry(amount: 1200, occurredDay: 20251101)
        _ = try world.insertEntry(amount: 999, occurredDay: 20251102)
        try world.markDeleted(deletedID, atDay: 20251120)

        let groups = try world.trash.groups(today: today)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.count, 1)
        XCTAssertEqual(groups[0].items[0].id, deletedID)
        XCTAssertEqual(try world.trash.count(), 1)
    }

    // MARK: - ⑤ 过期清理

    func testPurgeExpiredRemovesOnlyRecordsOlderThanRetention() throws {
        let world = try makeWorld()
        let expiredID = try world.insertEntry(amount: 100, occurredDay: 20251020)
        let boundaryID = try world.insertEntry(amount: 200, occurredDay: 20251021)

        // 保留期 30 天：31 天前删的过期，正好 30 天前删的**不过期**
        try world.markDeleted(expiredID, atDay: today.adding(days: -31).key)
        try world.markDeleted(boundaryID, atDay: today.adding(days: -30).key)

        XCTAssertEqual(try world.trash.purgeExpired(today: today), 1)

        XCTAssertNil(try world.writer.entry(id: expiredID), "31 天前删除的必须被物理删除")
        XCTAssertNotNil(try world.writer.entry(id: boundaryID), "30 天整仍在保留期内")
        XCTAssertEqual(try world.trash.count(), 1)
    }

    func testPurgeAllPhysicallyDeletesEverything() throws {
        let world = try makeWorld()
        let firstID = try world.insertEntry(amount: 100, occurredDay: 20251101)
        let secondID = try world.insertEntry(amount: 200, occurredDay: 20251102)
        let liveID = try world.insertEntry(amount: 300, occurredDay: 20251103)
        try world.markDeleted(firstID, atDay: 20251105)
        try world.markDeleted(secondID, atDay: 20251106)

        XCTAssertEqual(try world.trash.purgeAll(), 2)
        XCTAssertEqual(try world.trash.count(), 0)
        XCTAssertNil(try world.writer.entry(id: firstID))
        XCTAssertNil(try world.writer.entry(id: secondID))
        XCTAssertNotNil(try world.writer.entry(id: liveID), "未删除的账目不受影响")
    }

    func testPurgeSingleEntryIsPhysical() throws {
        let world = try makeWorld()
        let id = try world.insertEntry(amount: 100, occurredDay: 20251101)
        try world.markDeleted(id, atDay: 20251105)

        try world.trash.purge(id)
        XCTAssertNil(try world.writer.entry(id: id))
        XCTAssertEqual(try world.trash.count(), 0)
    }

    // MARK: - ⑥ 恢复（含订阅抑制表回退）

    func testRestoreUnsuppressesSubscriptionCycleAndKeepsIdentity() throws {
        let world = try makeWorld()

        let created = try world.subscription.create(
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: 20251001),
            today: today
        )
        let cycleKey = "2025-11"
        try world.subscription.suppress(cycleKey: cycleKey, of: created.subscriptionID)

        // 造一笔"订阅自动生成的待确认账目"
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: 2500, occurredDay: 20251115)
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = created.subscriptionID
        draft.sourceCycleKey = cycleKey
        draft.confirmRaw = EntryConfirmation.pending.raw
        draft.uniqueKey = SubscriptionSnapshot.makeUniqueKey(
            subscriptionID: created.subscriptionID,
            cycleKey: cycleKey
        )
        let id = try XCTUnwrap(try world.writer.insert(draft).entryID)
        let before = try XCTUnwrap(try world.writer.entry(id: id))
        let createdAtBefore = before.createdAt
        let uniqueKeyBefore = before.sourceCycleUniqueKey

        try world.markDeleted(id, atDay: 20251119)
        XCTAssertEqual(try world.trash.count(), 1)

        try world.trash.restore(id, at: DateOnly(key: 20251120).date)

        let restored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.deletedDay, 0)
        // PRD 6.3-5：pending 账目恢复后仍是 pending，不能悄悄变成已确认
        XCTAssertEqual(restored.confirmRaw, EntryConfirmation.pending.raw)
        // 恢复后 createdAt / 幂等键与删除前完全一致（PRD 6.4）
        XCTAssertEqual(restored.createdAt, createdAtBefore)
        XCTAssertEqual(restored.sourceCycleUniqueKey, uniqueKeyBefore)

        // 抑制表已回退：该周期不再被抑制（PRD 6.3-1）
        let subscription = try XCTUnwrap(try world.subscription.subscription(id: created.subscriptionID))
        XCTAssertFalse(subscription.suppressedCycleSet.contains(cycleKey))
        XCTAssertEqual(try world.trash.count(), 0)
    }

    func testRestoreKeepsEntryWhenSubscriptionWasDeleted() throws {
        let world = try makeWorld()

        let created = try world.subscription.create(
            SubscriptionDraft(name: "云盘", amount: 1200, firstBillingDay: 20251001),
            today: today
        )
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: 1200, occurredDay: 20251110)
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = created.subscriptionID
        draft.sourceCycleKey = "2025-11"
        let id = try XCTUnwrap(try world.writer.insert(draft).entryID)
        try world.markDeleted(id, atDay: 20251115)

        // 订阅被删掉之后再恢复：找不到订阅必须静默跳过（PRD 6.3-4），不能抛错
        try world.subscription.delete(id: created.subscriptionID)
        XCTAssertNoThrow(try world.trash.restore(id, at: Date()))

        let restored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(restored.deletedDay, 0)
    }

    func testRestoreThrowsWhenEntryIsGone() throws {
        let world = try makeWorld()
        XCTAssertThrowsError(try world.trash.restore(UUID(), at: Date())) { error in
            XCTAssertEqual(error as? TrashError, .entryNotFound)
        }
    }

    // MARK: - ⑦ 模板服务

    func testTemplateCreateRejectsEmptyAndTooLongNames() throws {
        let world = try makeWorld()

        XCTAssertThrowsError(try world.template.create(TemplateDraft(name: "   "))) { error in
            XCTAssertEqual(error as? TemplateError, .nameEmpty)
        }
        let tooLong = String(repeating: "模", count: TemplateService.nameLimit + 1)
        XCTAssertThrowsError(try world.template.create(TemplateDraft(name: tooLong))) { error in
            XCTAssertEqual(error as? TemplateError, .nameTooLong)
        }
        XCTAssertEqual(try world.template.count(), 0, "校验失败不能留下半条记录")
    }

    func testTemplateTwentyFirstCreateThrowsLimitReached() throws {
        let world = try makeWorld()
        for index in 0..<TemplateService.limit {
            try world.template.create(
                TemplateDraft(
                    name: "模板\(index)",
                    amount: 2500,
                    hasAmount: true,
                    note: "午饭",
                    categoryID: world.expenseCategoryID,
                    accountID: world.accountID
                )
            )
        }
        XCTAssertEqual(try world.template.count(), TemplateService.limit)
        XCTAssertFalse(try world.template.canCreate())

        XCTAssertThrowsError(
            try world.template.create(TemplateDraft(name: "第 21 个", amount: 100, hasAmount: true))
        ) { error in
            XCTAssertEqual(error as? TemplateError, .limitReached)
        }
        XCTAssertEqual(try world.template.count(), TemplateService.limit)
    }

    func testTemplateCreateFillsRelationsAndDropsAmountWhenNotUsed() throws {
        let world = try makeWorld()

        let template = try world.template.create(
            TemplateDraft(
                name: "咖啡",
                amount: 3300,
                hasAmount: false,
                note: "冰美式",
                categoryID: world.expenseCategoryID,
                accountID: world.accountID
            )
        )

        XCTAssertEqual(template.name, "咖啡")
        XCTAssertEqual(template.typeRaw, EntryType.expense.raw)
        XCTAssertFalse(template.hasAmount)
        XCTAssertEqual(template.amount, 0, "hasAmount == false 时不该留下上次的金额")
        XCTAssertEqual(template.note, "冰美式")
        XCTAssertEqual(template.category?.id, world.expenseCategoryID)
        XCTAssertEqual(template.account?.id, world.accountID)
    }

    func testTemplateWithUnknownCategoryIDFallsBackToNil() throws {
        let world = try makeWorld()

        let template = try world.template.create(
            TemplateDraft(name: "幽灵分类", amount: 100, hasAmount: true, categoryID: UUID())
        )
        XCTAssertNil(template.category, "解析不到的分类静默置 nil，不抛错（PRD 5.3-4）")
    }

    func testTemplateReorderPersistsStableOrder() throws {
        let world = try makeWorld()
        let first = try world.template.create(TemplateDraft(name: "A", amount: 100, hasAmount: true))
        let second = try world.template.create(TemplateDraft(name: "B", amount: 200, hasAmount: true))
        let third = try world.template.create(TemplateDraft(name: "C", amount: 300, hasAmount: true))

        XCTAssertEqual(try world.template.all().map(\.name), ["A", "B", "C"])

        try world.template.reorder(orderedIDs: [third.id, first.id, second.id])
        XCTAssertEqual(try world.template.all().map(\.name), ["C", "A", "B"])

        // 顺序必须落库（换一只 context 重新读，验证的是"提交了"而不是"内存里改过"）
        let freshContext = ModelContext(world.container)
        let freshOrder = try freshContext.fetch(FetchDescriptor<EntryTemplate>())
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.name)
        XCTAssertEqual(freshOrder, ["C", "A", "B"])
    }

    func testTemplateMakeFromEntryCopiesFields() throws {
        let world = try makeWorld()
        let id = try world.insertEntry(amount: 2500, occurredDay: 20251120, note: "午饭")

        let template = try world.template.makeFrom(entryID: id, name: "午饭模板")
        XCTAssertEqual(template.name, "午饭模板")
        XCTAssertEqual(template.amountMoney, Money(cents: 2500))
        XCTAssertTrue(template.hasAmount)
        XCTAssertEqual(template.note, "午饭")
        XCTAssertEqual(template.typeRaw, EntryType.expense.raw)
    }

    func testTemplateDeleteNeverTouchesEntries() throws {
        let world = try makeWorld()
        let template = try world.template.create(
            TemplateDraft(name: "午饭", amount: 2500, hasAmount: true, categoryID: world.expenseCategoryID)
        )
        let id = try world.insertEntry(amount: 2500, occurredDay: 20251120, note: "午饭")

        try world.template.delete(id: template.id)

        XCTAssertEqual(try world.template.count(), 0)
        let stored = try XCTUnwrap(try world.writer.entry(id: id))
        XCTAssertEqual(stored.amount, 2500, "模板是输入辅助，不是数据源（PRD 5.3-5）")
        XCTAssertEqual(stored.category?.id, world.expenseCategoryID)
    }

    func testTemplateCountAndDeleteAreIdempotent() throws {
        let world = try makeWorld()
        let template = try world.template.create(TemplateDraft(name: "临时", amount: 100, hasAmount: true))

        try world.template.delete(id: template.id)
        // 再删一次：静默返回，不抛错
        XCTAssertNoThrow(try world.template.delete(id: template.id))
        // 编辑一个不存在的模板：同样静默返回
        XCTAssertNoThrow(try world.template.update(id: template.id, changing: TemplateDraft(name: "改名")))
        XCTAssertEqual(try world.template.count(), 0)
    }

    // MARK: - 夹具

    /// 一套真容器 + 已种子化的服务组。
    fileprivate struct World {
        let container: ModelContainer
        let writer: LedgerWriter
        let ledger: LedgerService
        let subscription: SubscriptionService
        let trash: TrashService
        let template: TemplateService
        let expenseCategoryID: UUID?
        let accountID: UUID?
    }

    private func makeWorld() throws -> World {
        let container = try ModelContainerFactory.make(inMemory: true)
        try SeedData.seedIfNeeded(in: container)
        let writer = LedgerWriter(container: container)
        let ledger = LedgerService(writer: writer)
        let subscription = SubscriptionService(writer: writer, ledger: ledger)
        let trash = TrashService(writer: writer, subscription: subscription)
        let template = TemplateService(writer: writer)

        let categoryID = try writer.fetch(QueryDescriptors.categories(of: .expense)).first?.id
        let accountID = try writer.fetch(QueryDescriptors.accounts()).first?.id

        return World(
            container: container,
            writer: writer,
            ledger: ledger,
            subscription: subscription,
            trash: trash,
            template: template,
            expenseCategoryID: categoryID,
            accountID: accountID
        )
    }
}

// MARK: - 夹具上的小工具

@MainActor
private extension SchemaV2Tests.World {

    /// 插一笔带分类与账户的账目（关系齐全，避免制造孤儿数据干扰断言语义）。
    @discardableResult
    func insertEntry(amount: Int64, occurredDay: Int32, note: String = "") throws -> UUID {
        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: amount, occurredDay: occurredDay)
        draft.note = note
        draft.categoryID = expenseCategoryID
        draft.accountID = accountID
        let outcome = try writer.insert(draft)
        guard let id = outcome.entryID else {
            throw NSError(domain: "SchemaV2Tests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "插入被幂等键拒绝：\(outcome)"
            ])
        }
        return id
    }

    /// 以"某个自然日"为删除时刻软删（`deletedDay` 由 `DateOnly` 反算，与线上一致）。
    func markDeleted(_ entryID: UUID, atDay day: Int32) throws {
        guard let entry = try writer.entry(id: entryID) else {
            throw NSError(domain: "SchemaV2Tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "找不到账目 \(entryID)"
            ])
        }
        try writer.markDeleted(entry, at: DateOnly(key: day).date)
    }
}
