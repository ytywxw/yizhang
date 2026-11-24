//
//  QueryDescriptors.swift
//  一账 / Core / Persistence
//
//  职责：全项目 `FetchDescriptor` 的唯一来源。
//
//  为什么不许 View 手搓谓词（架构 §2 目录红线）：
//  "某月账目"这类查询依赖 `yyyyMMdd` 整数区间 + 软删过滤 + 排序，是**高危逻辑**：
//  任何一处把 `occurredDay <= upper` 写成 `<`，用户就会看到少一天的月报，而这种错很难被发现。
//  集中到本文件后，它只有一份实现、一份单测。
//
//  三条硬规则：
//  ① 谓词里**只用整数与字符串比较**——不用 `Calendar`、不用枚举、不调用任何方法
//     （iOS 17 的 `#Predicate` 对这些支持不稳，且 Optional<Date> 比较有已知崩溃面）；
//  ② 账目查询**默认带 `deletedAt == nil`**，软删记录不进入任何列表与统计；
//  ③ 入参一律 `Int32` 月份键 / 日键，**绝不传 `Date`**——`@Query` 用值相等判断是否重建，
//     传 `Date` 会让每次 body 求值都重建查询，列表跟着抖动。
//

import Foundation
import SwiftData

/// `FetchDescriptor` 工厂。全部方法都是 `static` 纯函数，无状态。
enum QueryDescriptors {

    // MARK: - 账目

    /// 某个月的账目（未软删），按日期倒序、同一天按创建时间倒序。
    ///
    /// 这是首页与统计页的主力查询。区间来自 `DateOnly.monthRange`，
    /// 所以"跨月边界"只有一处实现。
    static func monthEntries(_ monthKey: Int32) -> FetchDescriptor<LedgerEntry> {
        let range = DateOnly.monthRange(monthKey)
        let lower = range.lowerBound
        let upper = range.upperBound
        return FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in
                entry.occurredDay >= lower && entry.occurredDay <= upper && entry.deletedAt == nil
            },
            sortBy: [
                SortDescriptor(\LedgerEntry.occurredDay, order: .reverse),
                SortDescriptor(\LedgerEntry.createdAt, order: .reverse)
            ]
        )
    }

    /// 某个月的分页账目（R-LIST-3：50 条/页）。
    ///
    /// iOS 17 的 `@Query` 不支持分页，所以列表滚到底时用这个 descriptor 手动 fetch。
    static func monthEntries(_ monthKey: Int32, limit: Int, offset: Int) -> FetchDescriptor<LedgerEntry> {
        var descriptor = monthEntries(monthKey)
        descriptor.fetchLimit = max(limit, 1)
        descriptor.fetchOffset = max(offset, 0)
        return descriptor
    }

    // 注：**刻意不提供**按分类的 descriptor。
    // `entry.category?.id == target` 属于"Optional 关系"谓词，iOS 17 的 `#Predicate` 对它有
    // 已知崩溃面（R10）。分类下钻的正确做法是 `monthEntries(_:)` 取单月后按 `categoryID` 过滤，
    // 单月数据量 ≤ 400 条，内存过滤的代价可以忽略。

    /// 复制的单条账目（含软删记录——撤销与自检需要看到它们）。
    static func entry(id: UUID) -> FetchDescriptor<LedgerEntry> {
        let target = id
        return FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in entry.id == target }
        )
    }

    /// 最近 N 条账目（首页"今日速览"用，跨月）。
    static func recentEntries(limit: Int) -> FetchDescriptor<LedgerEntry> {
        var descriptor = FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in entry.deletedAt == nil },
            sortBy: [SortDescriptor(\LedgerEntry.occurredDay, order: .reverse)]
        )
        descriptor.fetchLimit = max(limit, 1)
        return descriptor
    }

    /// 全量账目（导出、自检、余额计算用）。**包含软删记录**，由调用方自己决定是否过滤。
    static func allEntries() -> FetchDescriptor<LedgerEntry> {
        FetchDescriptor<LedgerEntry>(
            sortBy: [SortDescriptor(\LedgerEntry.occurredDay, order: .forward)]
        )
    }

    /// 按幂等键查重（第 2 层防线的载体）。
    ///
    /// `includePendingChanges = true` 是关键：同一批次里连续插入同一周期时，
    /// 第二条虽然还没 `save()`，也必须被挡住，否则会落两条。
    static func entry(withUniqueKey key: String) -> FetchDescriptor<LedgerEntry> {
        var descriptor = FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in entry.sourceCycleUniqueKey == key }
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return descriptor
    }

    /// 某来源的全部账目（**含软删记录**）。
    ///
    /// 用途：结算扫描在阶段 1 一次性取回"已有的订阅幂等键"，把 N 次 `fetchCount`
    /// 压成 1 次 fetch（架构 §5.1 的优化②）。含软删是有意的：
    /// R-SUB-7 规定幂等键在**含软删记录**范围内唯一，一条被软删的订阅账目仍占用它的周期。
    static func entries(ofSource source: EntrySource) -> FetchDescriptor<LedgerEntry> {
        let raw = source.raw
        return FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in entry.sourceRaw == raw },
            sortBy: [SortDescriptor(\LedgerEntry.occurredDay, order: .forward)]
        )
    }

    // MARK: - 账户 / 分类

    /// 全部账户，按手动排序。
    ///
    /// 注意：**不按 `isArchived` 排序**——`Bool` 不满足 `Comparable`，`SortDescriptor` 会退化成
    /// NSObject 版本并编译失败。需要"未归档在前"的调用方在内存里做一次稳定分区
    /// （账户总量 ≤ 10 条，代价为零）。
    static func accounts(includeArchived: Bool = true) -> FetchDescriptor<Account> {
        if includeArchived {
            return FetchDescriptor<Account>(
                sortBy: [SortDescriptor(\Account.sortOrder, order: .forward)]
            )
        }
        return FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in account.isArchived == false },
            sortBy: [SortDescriptor(\Account.sortOrder, order: .forward)]
        )
    }

    static func account(id: UUID) -> FetchDescriptor<Account> {
        let target = id
        return FetchDescriptor<Account>(
            predicate: #Predicate<Account> { account in account.id == target }
        )
    }

    /// 某类型的分类（支出 / 收入），按手动排序。
    ///
    /// 同 `accounts()`：不按 `isHidden`（Bool 非 Comparable）排序，隐藏项的置后由调用方在内存里做。
    static func categories(of type: EntryType, includeHidden: Bool = true) -> FetchDescriptor<Category> {
        let raw = type.raw
        if includeHidden {
            return FetchDescriptor<Category>(
                predicate: #Predicate<Category> { category in category.typeRaw == raw },
                sortBy: [SortDescriptor(\Category.sortOrder, order: .forward)]
            )
        }
        return FetchDescriptor<Category>(
            predicate: #Predicate<Category> { category in
                category.typeRaw == raw && category.isHidden == false
            },
            sortBy: [SortDescriptor(\Category.sortOrder, order: .forward)]
        )
    }

    static func category(id: UUID) -> FetchDescriptor<Category> {
        let target = id
        return FetchDescriptor<Category>(
            predicate: #Predicate<Category> { category in category.id == target }
        )
    }

    // MARK: - 订阅

    /// 结算扫描候选：`status == active` 且 `0 < nextBillingDay <= 今天`。
    ///
    /// 注意这里**不加 `autoRenew` 条件**：不自动续费的订阅也要被扫描到（R-SUB-6 只提醒不记账），
    /// 由 `SweepPlanner` 决定跳过写账还是发提醒。
    static func subscriptionScanCandidates(onOrBefore today: DateOnly) -> FetchDescriptor<Subscription> {
        let todayKey = today.key
        let activeRaw = SubscriptionStatus.active.raw
        return FetchDescriptor<Subscription>(
            predicate: #Predicate<Subscription> { subscription in
                subscription.nextBillingDay > 0
                    && subscription.nextBillingDay <= todayKey
                    && subscription.statusRaw == activeRaw
            },
            sortBy: [SortDescriptor(\Subscription.nextBillingDay, order: .forward)]
        )
    }

    /// 某状态的订阅，按下次扣费日升序（已取消的没有日期，排在最后）。
    static func subscriptions(of status: SubscriptionStatus) -> FetchDescriptor<Subscription> {
        let raw = status.raw
        return FetchDescriptor<Subscription>(
            predicate: #Predicate<Subscription> { subscription in subscription.statusRaw == raw },
            sortBy: [
                SortDescriptor(\Subscription.nextBillingDay, order: .forward),
                SortDescriptor(\Subscription.name, order: .forward)
            ]
        )
    }

    static func allSubscriptions() -> FetchDescriptor<Subscription> {
        FetchDescriptor<Subscription>(
            sortBy: [
                SortDescriptor(\Subscription.statusRaw, order: .forward),
                SortDescriptor(\Subscription.nextBillingDay, order: .forward)
            ]
        )
    }

    static func subscription(id: UUID) -> FetchDescriptor<Subscription> {
        let target = id
        return FetchDescriptor<Subscription>(
            predicate: #Predicate<Subscription> { subscription in subscription.id == target }
        )
    }

    // MARK: - 待办

    /// 未完成待办，按截止日升序（无日期的排在最后）。
    static func openTodos() -> FetchDescriptor<Todo> {
        let openRaw = TodoStatus.open.raw
        return FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in todo.statusRaw == openRaw },
            sortBy: [
                SortDescriptor(\Todo.dueDay, order: .forward),
                SortDescriptor(\Todo.priorityRaw, order: .reverse)
            ]
        )
    }

    /// 未完成且截止日不晚于某天的待办（"今天/本周"分组与逾期计数）。
    static func openTodos(dueOnOrBefore day: DateOnly) -> FetchDescriptor<Todo> {
        let openRaw = TodoStatus.open.raw
        let dayKey = day.key
        return FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.statusRaw == openRaw && todo.dueDay > 0 && todo.dueDay <= dayKey
            },
            sortBy: [SortDescriptor(\Todo.dueDay, order: .forward)]
        )
    }

    /// 无截止日期的未完成待办。
    static func openTodosWithoutDueDate() -> FetchDescriptor<Todo> {
        let openRaw = TodoStatus.open.raw
        return FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in
                todo.statusRaw == openRaw && todo.dueDay == 0
            },
            sortBy: [SortDescriptor(\Todo.priorityRaw, order: .reverse)]
        )
    }

    static func allTodos() -> FetchDescriptor<Todo> {
        FetchDescriptor<Todo>(
            sortBy: [
                SortDescriptor(\Todo.statusRaw, order: .forward),
                SortDescriptor(\Todo.dueDay, order: .forward)
            ]
        )
    }

    static func todo(id: UUID) -> FetchDescriptor<Todo> {
        let target = id
        return FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { todo in todo.id == target }
        )
    }

    // MARK: - 设置

    /// 设置行（正常只有一条，由 `SeedData` 幂等保证）。
    static func appSettings() -> FetchDescriptor<AppSettings> {
        FetchDescriptor<AppSettings>()
    }
}
