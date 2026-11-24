//
//  ModelContainerTests.swift
//  一账Tests / Persistence
//
//  验证 T04（容器与模型）+ T05（写入器）的契约：
//  ① in-memory 容器能创建（CloudKit 形状的约束没有让 schema 变非法）；
//  ② 账目只能经 `LedgerWriter` 落库，且字段/默认值/计算属性正确；
//  ③ Account ↔ LedgerEntry 的反向关系双向生效（含转账的 incomingTransfers）；
//  ④ `Diagnostics` 能识别人为制造的重复幂等键。
//
//  注：`LedgerEntry.init()` 已在 T06 收窄为 `fileprivate`（A3），
//  因此本文件不再直接 `LedgerEntry()`，一律走 `LedgerWriter.insert(EntryDraft)`。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class ModelContainerTests: XCTestCase {

    // MARK: - 容器

    func testInMemoryContainerCanBeCreated() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        XCTAssertFalse(container.configurations.isEmpty)

        // 六个模型都必须能在容器里取到上下文（schema 注册完整）
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 0)
        // 用 `YiZhang.Category` 限定：测试宿主环境下 `Category` 有同名符号，直接用会歧义
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<YiZhang.Category>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Subscription>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Todo>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 0)
    }

    func testSchemaV1DeclaresSixModels() async throws {
        XCTAssertEqual(SchemaV1.models.count, 6)
        XCTAssertEqual(SchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
        XCTAssertTrue(YiZhangMigrationPlan.stages.isEmpty)

        let schema = Schema(versionedSchema: SchemaV1.self)
        XCTAssertEqual(Diagnostics.check(schema: schema).modelCount, 6)
    }

    func testInMemoryForPreviewIsUsable() async throws {
        let container = try ModelContainerFactory.inMemoryForPreview()
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSettings>()), 0)
    }

    // MARK: - 插入与取回

    func testInsertThroughWriterAndFetch() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        var draft = EntryDraft(typeRaw: EntryType.expense.raw, amount: 2800, occurredDay: 20251120)
        draft.note = "午饭"
        let outcome = try writer.insert(draft)

        let insertedID = try XCTUnwrap(outcome.entryID)
        let context = ModelContext(container)
        let fetched = try context.fetch(FetchDescriptor<LedgerEntry>())
        XCTAssertEqual(fetched.count, 1)

        let stored = try XCTUnwrap(fetched.first)
        XCTAssertEqual(stored.id, insertedID)
        XCTAssertEqual(stored.amount, 2800)
        XCTAssertEqual(stored.amountMoney, Money(cents: 2800))
        XCTAssertEqual(stored.typeRaw, EntryType.expense.raw)
        XCTAssertEqual(stored.occurredDay, 20251120)
        XCTAssertEqual(stored.occurredDate, DateOnly(key: 20251120))
        XCTAssertEqual(stored.monthKey, 202511)
        XCTAssertEqual(stored.sourceRaw, EntrySource.manual.raw)
        XCTAssertFalse(stored.isDeleted)
        XCTAssertTrue(stored.isActive)
        XCTAssertNil(stored.deletedAt)
        XCTAssertNil(stored.sourceCycleUniqueKey)

        // 写入器会写审计字段（不再是 1970 的默认值）
        XCTAssertGreaterThan(stored.createdAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(stored.createdAt, stored.updatedAt)
    }

    func testAccountEntriesInverseRelationship() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let account = Account()
        account.name = "微信"
        account.kind = .wechat
        account.initialBalanceMoney = Money(cents: 10_000)
        writer.modelContext.insert(account)
        try writer.save()

        var draft = EntryDraft(amount: 2500, occurredDay: 20251120)
        draft.accountID = account.id
        try writer.insert(draft)

        let context = ModelContext(container)
        let storedAccount = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Account>()).first
        )
        XCTAssertEqual(storedAccount.kind, .wechat)
        XCTAssertEqual(storedAccount.initialBalanceMoney, Money(cents: 10_000))
        XCTAssertEqual(storedAccount.entries?.count, 1, "Account.entries 的 inverse 应自动带上新账目")
        XCTAssertEqual(storedAccount.entries?.first?.amount, 2500)
        XCTAssertTrue(storedAccount.hasAnyEntries)

        let storedEntry = try XCTUnwrap(try context.fetch(FetchDescriptor<LedgerEntry>()).first)
        XCTAssertEqual(storedEntry.account?.name, "微信")
    }

    func testTransferRelationshipKeepsBothSides() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let cash = Account()
        cash.name = "现金"
        cash.kind = .cash
        let card = Account()
        card.name = "储蓄卡"
        card.kind = .debit
        writer.modelContext.insert(cash)
        writer.modelContext.insert(card)
        try writer.save()

        var draft = EntryDraft(typeRaw: EntryType.transfer.raw, amount: 5000, occurredDay: 20251201)
        draft.accountID = cash.id
        draft.toAccountID = card.id
        try writer.insert(draft)

        let context = ModelContext(container)
        let storedTransfer = try XCTUnwrap(try context.fetch(FetchDescriptor<LedgerEntry>()).first)
        XCTAssertTrue(storedTransfer.isTransfer)
        XCTAssertTrue(storedTransfer.isTransferComplete)
        XCTAssertEqual(storedTransfer.account?.name, "现金")
        XCTAssertEqual(storedTransfer.toAccount?.name, "储蓄卡")

        let accounts = try context.fetch(QueryDescriptors.accounts())
        let storedCash = try XCTUnwrap(accounts.first { $0.name == "现金" })
        let storedCard = try XCTUnwrap(accounts.first { $0.name == "储蓄卡" })
        XCTAssertEqual(storedCash.entries?.count, 1)
        XCTAssertEqual(storedCash.incomingTransfers?.count, 0)
        XCTAssertEqual(storedCard.incomingTransfers?.count, 1, "转入账户应通过 incomingTransfers 反查到转账")
    }

    func testSubscriptionAndTodoComputedProperties() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)

        let subscription = Subscription()
        subscription.name = "视频会员"
        subscription.amountMoney = Money(cents: 2500)
        subscription.cycleUnit = .month
        subscription.cycleValue = 1
        subscription.billingAnchorDay = 31
        subscription.nextBillingDate = DateOnly(key: 20250131)
        subscription.trialEndDate = nil
        context.insert(subscription)

        let todo = Todo()
        todo.title = "周末买菜"
        todo.hasExpense = true
        todo.estimatedMoney = Money(cents: 20_000)
        todo.dueDate = DateOnly(key: 20251122)
        todo.priority = .high
        todo.repeatRule = .weekly
        todo.repeatInterval = 1
        context.insert(todo)

        try context.save()

        let storedSubscription = try XCTUnwrap(try context.fetch(FetchDescriptor<Subscription>()).first)
        XCTAssertEqual(storedSubscription.cycleUnit, .month)
        XCTAssertEqual(storedSubscription.nextBillingDate, DateOnly(key: 20250131))
        XCTAssertEqual(storedSubscription.cycleText, "每月")
        XCTAssertNil(storedSubscription.trialEndDate)
        XCTAssertTrue(storedSubscription.status == .active)

        // 置空下次扣费日 → 0 哨兵 → 计算属性返回 nil（E-3）
        storedSubscription.nextBillingDate = nil
        XCTAssertEqual(storedSubscription.nextBillingDay, 0)
        XCTAssertNil(storedSubscription.nextBillingDate)

        let storedTodo = try XCTUnwrap(try context.fetch(FetchDescriptor<Todo>()).first)
        XCTAssertTrue(storedTodo.hasExpense)
        XCTAssertEqual(storedTodo.estimatedMoney, Money(cents: 20_000))
        XCTAssertEqual(storedTodo.dueDate, DateOnly(key: 20251122))
        XCTAssertEqual(storedTodo.priority, .high)
        XCTAssertEqual(storedTodo.status, .open)
        XCTAssertEqual(storedTodo.repeatRule, .weekly)
        XCTAssertEqual(storedTodo.repeatText, "每周")
    }

    // MARK: - 自检

    func testDiagnosticsDetectsDuplicateUniqueKeys() async throws {
        let container = try ModelContainerFactory.make(inMemory: true)
        let writer = LedgerWriter(container: container)

        let subscriptionID = UUID()
        let duplicatedKey = SubscriptionSnapshot.makeUniqueKey(
            subscriptionID: subscriptionID,
            cycleKey: "2025-11"
        )

        // 先插三条不同键的订阅账目，再把其中两条改成同一个键——
        // 这正是"某条路径漏了幂等检查"的真实形态（`LedgerWriter.insert` 会挡住直接重复插入）
        var insertedIDs: [UUID] = []
        for _ in 0..<2 {
            var draft = EntryDraft(amount: 2500, occurredDay: 20251125)
            draft.sourceRaw = EntrySource.subscription.raw
            draft.sourceRefID = subscriptionID
            draft.sourceCycleKey = "2025-11"
            draft.uniqueKey = nil
            let outcome = try writer.insert(draft)
            insertedIDs.append(try XCTUnwrap(outcome.entryID))
        }
        for (index, id) in insertedIDs.enumerated() {
            try writer.update(id: id) { entry in
                entry.sourceCycleUniqueKey = duplicatedKey
                // 拉开 createdAt，验证"保留最早一条"的排序前提
                entry.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            }
        }

        // 一条正常的不同键，不应被算进重复
        var uniqueDraft = EntryDraft(amount: 2500, occurredDay: 20251225)
        uniqueDraft.sourceRaw = EntrySource.subscription.raw
        uniqueDraft.uniqueKey = "\(UUID().uuidString)|2025-12"
        try writer.insert(uniqueDraft)

        // 一条手动记账（key 为 nil），也不应被算进重复
        try writer.insert(EntryDraft(amount: 100, occurredDay: 20251120))

        let context = ModelContext(container)
        let duplicates = try Diagnostics.duplicateUniqueKeys(in: context)
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[duplicatedKey]?.count, 2)

        let report = try Diagnostics.check(container: container)
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.duplicateUniqueKeyCounts[duplicatedKey], 2)
        XCTAssertEqual(report.duplicateEntryCount, 2)
        XCTAssertEqual(report.modelCount, 6)
    }
}
