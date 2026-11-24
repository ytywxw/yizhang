//
//  NotificationService.swift
//  一账 / Core / Services
//
//  职责：本地通知（T20）——订阅扣费 / 非自动续费到期 / 待办截止。
//
//  ## 五个刻意的设计
//
//  ① **ID 规则固定且可推导**（见 `NotificationPlanner`）：
//     `yizhang.sub.due.<订阅ID>.<yyyyMMdd>` / `yizhang.sub.renew.<订阅ID>.<yyyyMMdd>` /
//     `yizhang.todo.due.<待办ID>`。固定 ID 是"重算幂等"的前提——同一条待办重复注册
//     会覆盖而不是叠加，用户不会收到两条一样的提醒。
//  ② **规划是纯函数**（`NotificationPlanner.plan`）：窗口边界、60 条上限、跳过已完成，
//     这些规则用 0 个 `UNUserNotificationCenter` 就能测完。
//  ③ **权限与功能解耦**：被拒只是"收不到提醒"，记账、订阅扫描、待办一个都不能受影响。
//     所以本类**不抛错给业务层**，`rescheduleAll` 永远安静返回；权限状态只影响 UI 文案。
//  ④ **冷启动全量重算 + `removeAllPending`**：不做增量删除——增量规则一旦漏一条，
//     用户会收到"已经删掉的订阅"或"已经完成的待办"的提醒，而这个 bug 只在特定操作序列后出现。
//  ⑤ **滚动窗口 30 天 / 上限 60 条**：iOS 的 pending 上限是 64 条，留 4 条余量给将来。
//

import Foundation
import UserNotifications

// MARK: - 权限

/// 通知权限状态（把 `UNAuthorizationStatus` 收敛成 4 个业务态）。
enum NotificationPermission: String, Hashable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional

    /// 是否能真正发出通知。
    var canDeliver: Bool {
        self == .authorized || self == .provisional
    }

    var displayName: String {
        switch self {
        case .notDetermined: return "未开启"
        case .denied: return "通知未开启"
        case .authorized: return "通知已开启"
        case .provisional: return "通知已开启（安静推送）"
        }
    }
}

// MARK: - 待注册的通知

/// 一条待注册的通知（值类型，便于测试断言）。
struct PendingNotification: Hashable, Sendable {
    let id: String
    let title: String
    let body: String
    /// 触发时刻。
    let fireDate: Date
    /// 触发所在的自然日（`yyyyMMdd`），测试与排序都按它。
    let fireDay: Int32
}

// MARK: - 系统通知中心的抽象

/// 通知中心客户端（真实实现包 `UNUserNotificationCenter`，测试用 fake）。
///
/// 抽象出来的唯一理由：单元测试里既不能弹权限弹窗，也不该依赖模拟器的系统状态。
protocol NotificationCenterClient: AnyObject {

    /// 当前权限状态。
    func permissionStatus() async -> NotificationPermission

    /// 请求权限（只在「用户第一次建带提醒的东西」时调用）。
    func requestPermission() async -> NotificationPermission

    /// 用 `requests` **整体替换** pending 队列。
    func replacePending(_ requests: [PendingNotification]) async

    /// 当前 pending 的 id 列表（测试与自检用）。
    func pendingIdentifiers() async -> [String]
}

// MARK: - 规划（纯函数）

/// 通知规划：输入订阅快照 + 待办种子，输出待注册列表。
enum NotificationPlanner {

    /// id 前缀（改这里等于改契约，测试会立刻红）。
    static let subscriptionDuePrefix = "yizhang.sub.due"
    static let subscriptionRenewPrefix = "yizhang.sub.renew"
    static let todoDuePrefix = "yizhang.todo.due"

    /// 滚动窗口（天）。
    static let windowDays = 30
    /// iOS 上限 64，留 4 条余量。
    static let maximumPending = 60
    /// 默认提醒时刻（09:00）。
    static let defaultHour = 9

    // MARK: ID 规则

    static func subscriptionDueID(subscriptionID: UUID, day: DateOnly) -> String {
        "\(subscriptionDuePrefix).\(subscriptionID.uuidString).\(day.key)"
    }

    static func subscriptionRenewID(subscriptionID: UUID, day: DateOnly) -> String {
        "\(subscriptionRenewPrefix).\(subscriptionID.uuidString).\(day.key)"
    }

    static func todoDueID(todoID: UUID) -> String {
        "\(todoDuePrefix).\(todoID.uuidString)"
    }

    // MARK: 待办输入

    /// 通知规划用的待办轻量视图（避免把 `@Model` 传进纯函数）。
    struct TodoSeed: Hashable, Sendable {
        let id: UUID
        let title: String
        let dueDay: Int32
        /// 当日分钟数；`-1` = 用默认 09:00。
        let dueTimeMinutes: Int32
        let isDone: Bool

        init(id: UUID, title: String, dueDay: Int32, dueTimeMinutes: Int32, isDone: Bool) {
            self.id = id
            self.title = title
            self.dueDay = dueDay
            self.dueTimeMinutes = dueTimeMinutes
            self.isDone = isDone
        }
    }

    // MARK: 规划

    /// 算出未来 `windowDays` 天内要注册的全部通知。
    ///
    /// - Parameters:
    ///   - subscriptions: 订阅快照（只处理 `status == .active` 且 `nextBillingDay > 0`）。
    ///   - todos: 待办种子（只处理未完成且有截止日的）。
    ///   - today: 今天。
    ///   - windowDays: 滚动窗口。
    ///   - limit: 上限（超出按时间先后截断）。
    /// - Returns: 按触发日升序、id 唯一、不超过 `limit` 条。
    static func plan(
        subscriptions: [SubscriptionSnapshot],
        todos: [TodoSeed],
        today: DateOnly,
        windowDays: Int = windowDays,
        limit: Int = maximumPending
    ) -> [PendingNotification] {
        guard today.key > 0 else { return [] }
        let horizon = today.adding(days: max(windowDays, 0))
        var results: [PendingNotification] = []
        var seen = Set<String>()

        // ① 订阅：自动续费 → 扣费提醒；不自动续费 → 「今天到期」提醒
        for snapshot in subscriptions {
            guard snapshot.status == .active, snapshot.nextBillingDay > 0 else { continue }
            let dueDay = DateOnly(key: snapshot.nextBillingDay)

            if snapshot.autoRenew {
                // 触发日 = 下次扣费日 - 提醒天数（提醒天数 0 表示当天提醒）
                let fireDay = dueDay.adding(days: -max(snapshot.reminderDays, 0))
                guard fireDay >= today, fireDay <= horizon else { continue }
                let id = subscriptionDueID(subscriptionID: snapshot.id, day: dueDay)
                guard seen.insert(id).inserted else { continue }
                results.append(
                    PendingNotification(
                        id: id,
                        title: "订阅扣费",
                        body: "「\(snapshot.name)」今天扣费 \(Money(cents: max(snapshot.amount, 0)).formatted())",
                        fireDate: fireDate(on: fireDay, minutes: Int32(defaultHour * 60)),
                        fireDay: fireDay.key
                    )
                )
            } else {
                guard dueDay >= today, dueDay <= horizon else { continue }
                let id = subscriptionRenewID(subscriptionID: snapshot.id, day: dueDay)
                guard seen.insert(id).inserted else { continue }
                results.append(
                    PendingNotification(
                        id: id,
                        title: "订阅到期",
                        body: "「\(snapshot.name)」今天到期，续费了吗？",
                        fireDate: fireDate(on: dueDay, minutes: Int32(defaultHour * 60)),
                        fireDay: dueDay.key
                    )
                )
            }
        }

        // ② 待办：已完成 / 已删除 / 无日期 一律不注册
        for seed in todos {
            guard !seed.isDone, seed.dueDay > 0 else { continue }
            let dueDay = DateOnly(key: seed.dueDay)
            guard dueDay.isValid, dueDay >= today, dueDay <= horizon else { continue }
            let id = todoDueID(todoID: seed.id)
            guard seen.insert(id).inserted else { continue }
            let minutes = seed.dueTimeMinutes >= 0 ? seed.dueTimeMinutes : Int32(defaultHour * 60)
            results.append(
                PendingNotification(
                    id: id,
                    title: "待办到期",
                    body: "「\(seed.title)」今天要做",
                    fireDate: fireDate(on: dueDay, minutes: minutes),
                    fireDay: dueDay.key
                )
            )
        }

        // ③ 上限：先到先得（用户先看到最近的提醒）
        let sorted = results.sorted { lhs, rhs in
            if lhs.fireDay != rhs.fireDay { return lhs.fireDay < rhs.fireDay }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    /// 自然日 + 当日分钟数 → `Date`。
    static func fireDate(on day: DateOnly, minutes: Int32) -> Date {
        let clamped = min(max(Int(minutes), 0), 1439)
        let start = Calendar.current.startOfDay(for: day.date)
        return start.addingTimeInterval(TimeInterval(clamped * 60))
    }
}

// MARK: - 服务

/// 本地通知服务。
@MainActor
final class NotificationService {

    private let client: NotificationCenterClient

    /// 当前权限状态（UI 据此显示「通知未开启 › 前往系统设置」）。
    private(set) var permission: NotificationPermission = .notDetermined

    /// 最近一次注册的条数（自检用）。
    private(set) var lastScheduledCount = 0

    /// `#if DEBUG` 下用于截图「权限被拒」态（模拟器里没法真的拒权限）。
    static var permissionOverride: NotificationPermission?

    /// 指定客户端（测试注入 fake）。
    init(client: NotificationCenterClient) {
        self.client = client
    }

    /// 生产用初始化器。
    ///
    /// 为什么不用默认参数 `= SystemNotificationCenterClient()`：
    /// 默认参数在**非隔离上下文**里求值，而 `SystemNotificationCenterClient` 是
    /// `@MainActor` 类型，写成默认参数会编译报「调用主 actor 隔离的初始化器」。
    /// 拆成 `convenience init()` 后，构造发生在 `@MainActor` 上下文内。
    convenience init() {
        self.init(client: SystemNotificationCenterClient())
    }

    // MARK: - 权限

    /// 刷新权限状态（不请求）。
    @discardableResult
    func refreshPermission() async -> NotificationPermission {
        if let override = NotificationService.permissionOverride {
            permission = override
            return override
        }
        permission = await client.permissionStatus()
        return permission
    }

    /// 在「用户第一次创建带提醒的订阅/待办」时调用。
    ///
    /// - Returns: 是否可发通知。**被拒不抛错、不打断调用方**——提醒是增强，
    ///   不该让"创建订阅"这件事失败。
    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        if let override = NotificationService.permissionOverride {
            permission = override
            return override.canDeliver
        }
        let current = await client.permissionStatus()
        switch current {
        case .authorized, .provisional:
            permission = current
            return true
        case .denied:
            permission = .denied
            return false
        case .notDetermined:
            let granted = await client.requestPermission()
            permission = granted
            return granted.canDeliver
        }
    }

    // MARK: - 重算

    /// 冷启动 / 回前台的全量重算。
    ///
    /// **永远不抛错**：通知失败绝不能影响记账与扫描（硬要求）。
    ///
    /// - Parameters:
    ///   - subscriptions: 订阅快照。
    ///   - todos: 待办种子。
    ///   - today: 今天。
    /// - Returns: 实际注册的条数。
    @discardableResult
    func rescheduleAll(
        subscriptions: [SubscriptionSnapshot],
        todos: [NotificationPlanner.TodoSeed],
        today: DateOnly = DateOnly(Date())
    ) async -> Int {
        await refreshPermission()

        // 权限不可用：清空 pending（避免残留旧通知），然后安静退出
        guard permission.canDeliver else {
            await client.replacePending([])
            lastScheduledCount = 0
            return 0
        }

        let requests = NotificationPlanner.plan(
            subscriptions: subscriptions,
            todos: todos,
            today: today
        )
        await client.replacePending(requests)
        lastScheduledCount = requests.count
        return requests.count
    }

    /// 当前 pending 的 id（自检 / 测试用）。
    func pendingIdentifiers() async -> [String] {
        await client.pendingIdentifiers()
    }

    /// 是否需要显示「前往系统设置」。
    var needsSystemSettings: Bool {
        permission == .denied
    }
}

// MARK: - 真实实现

/// 包 `UNUserNotificationCenter` 的客户端。
@MainActor
final class SystemNotificationCenterClient: NotificationCenterClient {

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func permissionStatus() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestPermission() async -> NotificationPermission {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .authorized : .denied
        } catch {
            // 请求失败按"未授权"处理：提醒是增强功能，不能因此打断业务
            return .denied
        }
    }

    func replacePending(_ requests: [PendingNotification]) async {
        center.removeAllPendingNotificationRequests()
        for request in requests {
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.body
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: request.fireDate
            )
            // 不用 timeInterval：过一会儿重启会漂；日历触发器与"09:00 提醒"的语义一致
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let notification = UNNotificationRequest(
                identifier: request.id,
                content: content,
                trigger: trigger
            )
            try? await center.add(notification)
        }
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}
