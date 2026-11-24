//
//  NotificationServiceTests.swift
//  一账Tests / Services
//
//  T20 的验收点全部压在这里。本地通知是这个项目里**唯一一处"出错也不会有任何反馈"**的功能：
//  注册错了，用户只是"没收到提醒"或"收到了已经删掉的订阅的提醒"，
//  不会有崩溃、不会有错误弹窗，QA 手动点也未必复现。所以必须靠测试把规则钉死。
//
//  刻意覆盖的 13 个场景：
//  ① 三类通知的 ID 规则（固定、可推导）；
//  ② 自动续费 → 触发日 = 下次扣费日 − 提醒天数；
//  ③ 不自动续费 → 到期当天 + 指定文案；
//  ④ 已完成的待办不注册；
//  ⑤ 无截止日 / 已取消 / 已暂停的订阅不注册；
//  ⑥ 30 天滚动窗口：第 30 天**在**窗口内，第 31 天**不在**；
//  ⑦ 提醒日已经过去的订阅不补注册（避免开 App 时突然弹一条历史提醒）；
//  ⑧ 60 条上限按触发日截断（先到先得）；
//  ⑨ 重算幂等：连跑两次 pending 条数与 id 集合完全不变；
//  ⑩ 权限被拒时清空 pending 而非残留；
//  ⑪ 权限**只在 notDetermined 时**请求一次；
//  ⑫ `rescheduleAll` 永远不抛错（它根本没有 throws）；
//  ⑬ **权限被拒不影响记账与结算扫描**（硬要求，单独一组断言）。
//

import XCTest
import SwiftData
@testable import YiZhang

// MARK: - 规划（纯函数）

final class NotificationPlannerTests: XCTestCase {

    /// 固定"今天"：2026-11-21，窗口终点 2026-12-21（第 30 天）。
    private let today = DateOnly(key: 20261121)

    // MARK: ① ID 规则

    func testSubscriptionDueIDUsesFixedRule() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let text = NotificationPlanner.subscriptionDueID(
            subscriptionID: id,
            day: DateOnly(key: 20261205)
        )

        XCTAssertEqual(text, "yizhang.sub.due.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.20261205")
        XCTAssertTrue(text.hasPrefix(NotificationPlanner.subscriptionDuePrefix))
    }

    func testSubscriptionRenewIDUsesFixedRule() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        let text = NotificationPlanner.subscriptionRenewID(
            subscriptionID: id,
            day: DateOnly(key: 20261205)
        )

        XCTAssertEqual(text, "yizhang.sub.renew.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.20261205")
    }

    func testTodoDueIDUsesTodoIDOnly() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let text = NotificationPlanner.todoDueID(todoID: id)

        XCTAssertEqual(text, "yizhang.todo.due.11111111-2222-3333-4444-555555555555")
        XCTAssertFalse(text.contains("20261123"), "待办 ID 不带日期，重复注册靠它覆盖而不是叠加")
    }

    // MARK: ② 自动续费：触发日 = 应扣日 − 提醒天数

    func testAutoRenewSubscriptionFiresReminderDaysBeforeDueDay() {
        let id = UUID()
        let snapshot = makeSubscription(id: id, nextBillingDay: 20261205, reminderDays: 3)

        let plan = NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today)

        XCTAssertEqual(plan.count, 1)
        let item = plan[0]
        XCTAssertEqual(item.id, "yizhang.sub.due.\(id.uuidString).20261205", "ID 用的是**应扣日**")
        XCTAssertEqual(item.fireDay, 20261202, "触发日 = 12/05 − 3 天")
        XCTAssertTrue(item.body.contains("视频会员"))
    }

    func testAutoRenewSubscriptionWithZeroReminderDaysFiresOnDueDay() {
        let snapshot = makeSubscription(nextBillingDay: 20261205, reminderDays: 0)

        let plan = NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today)

        XCTAssertEqual(plan.first?.fireDay, 20261205)
    }

    func testSubscriptionWhoseReminderDayAlreadyPassedIsSkipped() {
        // 应扣日 11/23、提前 7 天 → 触发日 11/16 已经过去
        let snapshot = makeSubscription(nextBillingDay: 20261123, reminderDays: 7)

        let plan = NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today)

        XCTAssertTrue(plan.isEmpty, "已经错过的提醒日不该补注册，否则一开 App 就弹一条历史提醒")
    }

    // MARK: ③ 不自动续费：到期当天提醒续费

    func testNonAutoRenewSubscriptionFiresOnDueDayWithRenewCopy() {
        let id = UUID()
        let snapshot = makeSubscription(
            id: id,
            name: "健身房",
            nextBillingDay: 20261125,
            autoRenew: false
        )

        let plan = NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].id, "yizhang.sub.renew.\(id.uuidString).20261125")
        XCTAssertEqual(plan[0].fireDay, 20261125)
        XCTAssertEqual(plan[0].body, "「健身房」今天到期，续费了吗？")
    }

    // MARK: ④ 待办

    func testOpenTodoWithDueDayIsRegistered() {
        let seed = NotificationPlanner.TodoSeed(
            id: UUID(),
            title: "交电费",
            dueDay: 20261123,
            dueTimeMinutes: 20 * 60,
            isDone: false
        )

        let plan = NotificationPlanner.plan(subscriptions: [], todos: [seed], today: today)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].id, NotificationPlanner.todoDueID(todoID: seed.id))
        XCTAssertEqual(plan[0].fireDay, 20261123)
    }

    func testCompletedTodoIsNotRegistered() {
        let seed = NotificationPlanner.TodoSeed(
            id: UUID(),
            title: "买菜",
            dueDay: 20261123,
            dueTimeMinutes: -1,
            isDone: true
        )

        let plan = NotificationPlanner.plan(subscriptions: [], todos: [seed], today: today)

        XCTAssertTrue(plan.isEmpty, "已完成的待办绝不能留下提醒")
    }

    func testTodoWithoutDueDayIsNotRegistered() {
        let seed = NotificationPlanner.TodoSeed(
            id: UUID(),
            title: "想看的书",
            dueDay: 0,
            dueTimeMinutes: -1,
            isDone: false
        )

        let plan = NotificationPlanner.plan(subscriptions: [], todos: [seed], today: today)

        XCTAssertTrue(plan.isEmpty)
    }

    func testTodoDueTimeDefaultsToNineAM() {
        let seed = NotificationPlanner.TodoSeed(
            id: UUID(),
            title: "体检",
            dueDay: 20261125,
            dueTimeMinutes: -1,
            isDone: false
        )

        let plan = NotificationPlanner.plan(subscriptions: [], todos: [seed], today: today)
        guard let fireDate = plan.first?.fireDate else { return XCTFail("应注册 1 条默认提醒") }

        let components = Calendar.current.dateComponents([.hour, .minute], from: fireDate)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    func testTodoCustomDueTimeIsHonoured() {
        let seed = NotificationPlanner.TodoSeed(
            id: UUID(),
            title: "开会",
            dueDay: 20261125,
            dueTimeMinutes: 14 * 60 + 30,
            isDone: false
        )

        let plan = NotificationPlanner.plan(subscriptions: [], todos: [seed], today: today)
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: plan.first?.fireDate ?? Date()
        )

        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
    }

    // MARK: ⑤ 不该注册的订阅

    func testCancelledSubscriptionIsNotRegistered() {
        let snapshot = makeSubscription(
            nextBillingDay: 20261125,
            statusRaw: SubscriptionStatus.cancelled.raw
        )

        XCTAssertTrue(
            NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today).isEmpty
        )
    }

    func testPausedSubscriptionIsNotRegistered() {
        let snapshot = makeSubscription(
            nextBillingDay: 20261125,
            statusRaw: SubscriptionStatus.paused.raw
        )

        XCTAssertTrue(
            NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today).isEmpty
        )
    }

    func testSubscriptionWithoutNextBillingDayIsNotRegistered() {
        let snapshot = makeSubscription(nextBillingDay: 0)

        XCTAssertTrue(
            NotificationPlanner.plan(subscriptions: [snapshot], todos: [], today: today).isEmpty
        )
    }

    // MARK: ⑥ 30 天窗口边界

    func testWindowIncludesDay30AndExcludesDay31() {
        let day30 = makeSubscription(name: "第30天", nextBillingDay: 20261221, autoRenew: false)
        let day31 = makeSubscription(name: "第31天", nextBillingDay: 20261222, autoRenew: false)

        let plan = NotificationPlanner.plan(
            subscriptions: [day30, day31],
            todos: [],
            today: today
        )

        XCTAssertEqual(plan.count, 1, "第 30 天在窗口内，第 31 天不在")
        XCTAssertEqual(plan.first?.fireDay, 20261221)
    }

    func testTodoOnDay31IsExcluded() {
        let inside = NotificationPlanner.TodoSeed(
            id: UUID(), title: "窗口内", dueDay: 20261221, dueTimeMinutes: -1, isDone: false
        )
        let outside = NotificationPlanner.TodoSeed(
            id: UUID(), title: "窗口外", dueDay: 20261222, dueTimeMinutes: -1, isDone: false
        )

        let plan = NotificationPlanner.plan(
            subscriptions: [],
            todos: [inside, outside],
            today: today
        )

        XCTAssertEqual(plan.map(\.body), ["「窗口内」今天要做"])
    }

    // MARK: ⑦ 上限

    func testPendingIsCappedAtSixty() {
        // 70 条待办全部落在窗口内 → 只留最近的 60 条
        let todos = (0..<70).map { index in
            NotificationPlanner.TodoSeed(
                id: UUID(),
                title: "待办\(index)",
                dueDay: DateOnly(key: 20261122).adding(days: index % 29).key,
                dueTimeMinutes: -1,
                isDone: false
            )
        }

        let plan = NotificationPlanner.plan(subscriptions: [], todos: todos, today: today)

        XCTAssertEqual(plan.count, NotificationPlanner.maximumPending)
        XCTAssertEqual(plan.count, 60)
        XCTAssertLessThanOrEqual(plan.count, 60, "iOS 上限 64，必须留余量")
        XCTAssertEqual(Set(plan.map(\.id)).count, 60, "截断后不能出现重复 id")
        XCTAssertEqual(plan.first?.fireDay, 20261122, "先到先得：最近的提醒必须保留")
    }

    func testPlanIsSortedByFireDay() {
        let later = NotificationPlanner.TodoSeed(
            id: UUID(), title: "晚", dueDay: 20261129, dueTimeMinutes: -1, isDone: false
        )
        let earlier = NotificationPlanner.TodoSeed(
            id: UUID(), title: "早", dueDay: 20261123, dueTimeMinutes: -1, isDone: false
        )

        let plan = NotificationPlanner.plan(
            subscriptions: [],
            todos: [later, earlier],
            today: today
        )

        XCTAssertEqual(plan.map(\.body), ["「早」今天要做", "「晚」今天要做"])
    }

    func testDuplicateSubscriptionSnapshotsProduceOneRequest() {
        let id = UUID()
        let first = makeSubscription(id: id, nextBillingDay: 20261205, autoRenew: false)
        let second = makeSubscription(id: id, nextBillingDay: 20261205, autoRenew: false)

        let plan = NotificationPlanner.plan(
            subscriptions: [first, second],
            todos: [],
            today: today
        )

        XCTAssertEqual(plan.count, 1, "同一订阅同一期只能有一条通知")
    }

    func testEmptyRepositoryProducesEmptyPlan() {
        XCTAssertTrue(NotificationPlanner.plan(subscriptions: [], todos: [], today: today).isEmpty)
    }

    // MARK: 夹具

    private func makeSubscription(
        id: UUID = UUID(),
        name: String = "视频会员",
        nextBillingDay: Int32,
        autoRenew: Bool = true,
        statusRaw: String = SubscriptionStatus.active.raw,
        reminderDays: Int = 1
    ) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: id,
            name: name,
            amount: 2500,
            statusRaw: statusRaw,
            autoRenew: autoRenew,
            nextBillingDay: nextBillingDay,
            reminderDays: reminderDays
        )
    }
}

// MARK: - 服务（注入 fake 通知中心）

@MainActor
final class NotificationServiceTests: XCTestCase {

    private let today = DateOnly(key: 20261121)

    func testRescheduleRegistersPlannedNotifications() async {
        let center = FakeNotificationCenter(permission: .authorized)
        let service = NotificationService(client: center)

        let count = await service.rescheduleAll(
            subscriptions: [makeSubscription(nextBillingDay: 20261125, autoRenew: false)],
            todos: [makeTodo(dueDay: 20261123)],
            today: today
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(service.lastScheduledCount, 2)
        XCTAssertEqual(center.pending.count, 2)
        XCTAssertFalse(service.needsSystemSettings)
    }

    func testRescheduleIsIdempotentAcrossTwoRuns() async {
        let center = FakeNotificationCenter(permission: .authorized)
        let service = NotificationService(client: center)
        let subscriptions = [
            makeSubscription(nextBillingDay: 20261125, autoRenew: false),
            makeSubscription(nextBillingDay: 20261205, reminderDays: 1)
        ]
        let todos = [makeTodo(dueDay: 20261123), makeTodo(dueDay: 20261128)]

        let firstCount = await service.rescheduleAll(
            subscriptions: subscriptions, todos: todos, today: today
        )
        let firstIdentifiers = await service.pendingIdentifiers()

        let secondCount = await service.rescheduleAll(
            subscriptions: subscriptions, todos: todos, today: today
        )
        let secondIdentifiers = await service.pendingIdentifiers()

        XCTAssertEqual(firstCount, 4)
        XCTAssertEqual(secondCount, firstCount, "重算两次条数必须不变")
        XCTAssertEqual(Set(firstIdentifiers), Set(secondIdentifiers), "不能出现重复 / 漂移的 id")
        XCTAssertEqual(firstIdentifiers.count, secondIdentifiers.count)
        XCTAssertEqual(center.pending.count, 4, "整体替换而不是追加，pending 不会叠加")
        XCTAssertEqual(center.replaceCount, 2)
    }

    func testRescheduleWithdrawsNotificationsWhenItemDisappears() async {
        let center = FakeNotificationCenter(permission: .authorized)
        let service = NotificationService(client: center)
        let live = makeTodo(dueDay: 20261123)

        _ = await service.rescheduleAll(subscriptions: [], todos: [live], today: today)
        XCTAssertEqual(center.pending.count, 1)

        // 待办被完成 / 删除后，下一次重算必须把它撤掉
        _ = await service.rescheduleAll(subscriptions: [], todos: [], today: today)

        XCTAssertTrue(center.pending.isEmpty, "已完成/已删除的待办必须被撤回")
        XCTAssertEqual(service.lastScheduledCount, 0)
    }

    func testDeniedPermissionClearsPendingAndReturnsZero() async {
        let center = FakeNotificationCenter(permission: .denied)
        center.seed([PendingNotification(id: "stale", title: "旧", body: "旧", fireDate: Date(), fireDay: 20261122)])
        let service = NotificationService(client: center)

        let count = await service.rescheduleAll(
            subscriptions: [makeSubscription(nextBillingDay: 20261125, autoRenew: false)],
            todos: [makeTodo(dueDay: 20261123)],
            today: today
        )

        XCTAssertEqual(count, 0)
        XCTAssertTrue(center.pending.isEmpty, "权限关掉后不能残留旧通知")
        XCTAssertEqual(service.permission, .denied)
        XCTAssertTrue(service.needsSystemSettings, "UI 要显示「通知未开启 › 前往系统设置」")
    }

    func testPermissionIsRequestedOnlyOnceWhenNotDetermined() async {
        let center = FakeNotificationCenter(permission: .notDetermined, grantsOnRequest: .authorized)
        let service = NotificationService(client: center)

        let first = await service.requestPermissionIfNeeded()
        let second = await service.requestPermissionIfNeeded()

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(center.requestCount, 1, "授权后不该再弹一次系统弹窗")
        XCTAssertEqual(service.permission, .authorized)
    }

    func testDeniedRequestDoesNotThrowAndReportsDenied() async {
        let center = FakeNotificationCenter(permission: .notDetermined, grantsOnRequest: .denied)
        let service = NotificationService(client: center)

        let granted = await service.requestPermissionIfNeeded()

        XCTAssertFalse(granted, "被拒只是返回 false，不抛错、不打断创建订阅")
        XCTAssertEqual(service.permission, .denied)
        XCTAssertTrue(service.needsSystemSettings)
    }

    func testRescheduleWhenNotDeterminedDoesNotRegister() async {
        let center = FakeNotificationCenter(permission: .notDetermined)
        let service = NotificationService(client: center)

        let count = await service.rescheduleAll(
            subscriptions: [makeSubscription(nextBillingDay: 20261125, autoRenew: false)],
            todos: [],
            today: today
        )

        XCTAssertEqual(count, 0, "还没授权就注册不进去，也不该在此处弹窗")
        XCTAssertEqual(center.requestCount, 0, "冷启动重算**不得**请求权限")
    }

    // MARK: 夹具

    private func makeSubscription(
        nextBillingDay: Int32,
        autoRenew: Bool = true,
        reminderDays: Int = 1
    ) -> SubscriptionSnapshot {
        SubscriptionSnapshot(
            id: UUID(),
            name: "视频会员",
            amount: 2500,
            autoRenew: autoRenew,
            nextBillingDay: nextBillingDay,
            reminderDays: reminderDays
        )
    }

    private func makeTodo(dueDay: Int32, isDone: Bool = false) -> NotificationPlanner.TodoSeed {
        NotificationPlanner.TodoSeed(
            id: UUID(),
            title: "交电费",
            dueDay: dueDay,
            dueTimeMinutes: -1,
            isDone: isDone
        )
    }
}

// MARK: - 权限被拒不能影响业务（硬要求）

@MainActor
final class NotificationIsolationTests: XCTestCase {

    /// 这一条是 T20 的**红线**：通知权限被拒 → 记账与订阅扫描必须一如既往。
    ///
    /// 为什么值得单独一个类：任何一个"顺手把通知放在写入路径里"的改动
    /// （比如 `try await requestPermission()` 插到 `LedgerService.create` 前面）
    /// 都会让"用户拒绝通知"变成"不能记账"。这条测试用真实 `AppEnvironment` +
    /// 真实容器跑，断言的就是这条链没被拧上。
    func testDeniedPermissionDoesNotAffectLedgerOrSweep() async throws {
        let today = DateOnly(key: 20261121)
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)

        // 模拟"用户在系统设置里关掉了通知"
        NotificationService.permissionOverride = .denied
        defer { NotificationService.permissionOverride = nil }

        // ① 通知重算：返回 0、不抛错、明确处于 denied
        let scheduled = await environment.rescheduleNotifications(today: today)
        XCTAssertEqual(scheduled, 0)
        XCTAssertEqual(environment.notifications.permission, .denied)
        XCTAssertTrue(environment.notifications.needsSystemSettings)

        // ② 记账照旧：这一步一旦 throw，测试就直接失败
        let before = try liveEntryCount(container)
        let categories = try environment.readContext.fetch(QueryDescriptors.categories(of: .expense))
        let accounts = try environment.readContext.fetch(QueryDescriptors.accounts())
        var draft = EntryDraft(amount: 1234, occurredDay: today.key)
        draft.categoryID = try XCTUnwrap(categories.first?.id)
        draft.accountID = try XCTUnwrap(accounts.first?.id)
        try environment.ledger.create(draft)
        XCTAssertEqual(try liveEntryCount(container), before + 1, "通知被拒时记账必须照常成功")

        // ③ 结算扫描照旧：照样生成到期那一期的账
        _ = try environment.subscription.create(
            SubscriptionDraft(name: "健身房", amount: 9900, firstBillingDay: today.key),
            today: today
        )
        let report = environment.sweep.sweep(today: today, force: true)

        XCTAssertEqual(report.inserted, 1, "通知被拒时扫描必须照样入账")
        XCTAssertTrue(report.failedSubscriptionIDs.isEmpty)
        XCTAssertEqual(try liveEntryCount(container), before + 2)
    }

    private func liveEntryCount(_ container: ModelContainer) throws -> Int {
        let writer = LedgerWriter(container: container)
        return try writer.fetch(QueryDescriptors.allEntries()).filter { $0.deletedAt == nil }.count
    }
}

// MARK: - Fake 通知中心

/// 内存版通知中心：把 `UNUserNotificationCenter` 换成两个数组。
///
/// 刻意实现"整体替换"语义（与真实实现一致）：
/// 只有真的替换，`testRescheduleIsIdempotentAcrossTwoRuns` 才能证明"重算不会叠加"。
@MainActor
private final class FakeNotificationCenter: NotificationCenterClient {

    private var status: NotificationPermission
    private var grantsOnRequest: NotificationPermission
    private(set) var pending: [PendingNotification] = []
    private(set) var replaceCount = 0
    private(set) var requestCount = 0

    init(
        permission: NotificationPermission,
        grantsOnRequest: NotificationPermission = .authorized
    ) {
        self.status = permission
        self.grantsOnRequest = grantsOnRequest
    }

    func seed(_ items: [PendingNotification]) {
        pending = items
    }

    func permissionStatus() async -> NotificationPermission {
        status
    }

    func requestPermission() async -> NotificationPermission {
        requestCount += 1
        status = grantsOnRequest
        return grantsOnRequest
    }

    func replacePending(_ requests: [PendingNotification]) async {
        replaceCount += 1
        pending = requests
    }

    func pendingIdentifiers() async -> [String] {
        pending.map(\.id)
    }
}
