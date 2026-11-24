//
//  SubscriptionListViewModel.swift
//  一账 / Features / Subscription
//
//  职责：订阅列表页的取数与分组——总览三数字、30 天时间轴、三组列表、行内文案、
//  以及"暂停/恢复/删除/已续费"四个用户动作的转译。
//
//  为什么分组与文案放在 VM 而不是 View：
//  ① "5 天后""已逾期 2 天"依赖"今天"，而"今天"必须在每次渲染前**一次算定**，
//     否则同一屏里两行可能跨过午夜拿到不同的 today（真机上极难复现的显示不一致）；
//  ② 分组规则（生效中按 nextBillingDay 升序 / 空组隐藏）是 PRD 4.5 的明文规定，
//     写成纯函数就能被单测覆盖，不必起 UI；
//  ③ View 只负责布局，测试可以直接断言 `groups` / `overview`。
//
//  `@Observable` 但**不加 `@MainActor`**：`@State private var viewModel = ...` 的初始化
//  发生在非隔离上下文，若类本身被标为 `@MainActor` 会编译失败；改由每个**方法**标注
//  `@MainActor`，效果等价（所有对 SwiftData 的访问仍在主线程）。
//

import Foundation
import Observation

/// 订阅列表视图模型。
@Observable
final class SubscriptionListViewModel {

    // MARK: - 展示模型

    /// 一行的全部展示数据（已算好文案，View 不再做任何日期/金额运算）。
    struct RowModel: Identifiable, Hashable {
        let id: UUID
        let name: String
        let iconName: String
        let colorHex: String
        /// 如「¥25 / 月」。
        let amountPerCycleText: String
        /// 如「11月25日（5天后）」/「11月25日（已逾期 2 天）」/「已取消」。
        let nextBillingText: String
        /// 排序用：下次扣费日 `yyyyMMdd`（0 表示无）。
        let nextBillingDayKey: Int32
        let status: SubscriptionStatus
        let autoRenew: Bool
        /// 是否处于试用中（E-1）。
        let isTrial: Bool
        /// 如「试用中，5 天后开始扣费」。
        let trialText: String?
        /// 待续费（R-SUB-6：不自动续费且已到期）。
        let isAwaitingRenewal: Bool
        /// 周期异常（命中 24 笔上限，R-SUB-5）。
        let isTruncated: Bool
    }

    /// 一个分组。
    struct GroupModel: Identifiable, Hashable {
        let status: SubscriptionStatus
        var rows: [RowModel]

        var id: String { status.raw }
        var title: String { status.displayName }
    }

    /// 总览卡数据。
    struct OverviewModel: Hashable {
        let monthlyFixedCost: Money
        let yearlyCost: Money
        let upcoming: [SubscriptionOverview.DueItem]
        let upcomingTotal: Money

        static let empty = OverviewModel(
            monthlyFixedCost: .zero,
            yearlyCost: .zero,
            upcoming: [],
            upcomingTotal: .zero
        )

        var upcomingCount: Int { upcoming.count }

        /// 是否有任何可展示的数字（全 0 且无时间轴时整张卡不出现）。
        var hasData: Bool {
            monthlyFixedCost.cents > 0 || yearlyCost.cents > 0 || !upcoming.isEmpty
        }
    }

    // MARK: - 状态

    /// 三个分组（空组已隐藏；顺序固定为 生效中 / 已暂停 / 已取消）。
    private(set) var groups: [GroupModel] = []

    /// 总览卡。
    private(set) var overview: OverviewModel = .empty

    /// 最近一次扫描的结果（用于「周期异常」打标与失败重试）。
    private(set) var lastSweepReport: SweepReport = SweepReport()

    /// 读取失败时的提示（不弹窗，横幅展示）。
    private(set) var errorMessage: String?

    /// 是否正在读取。
    private(set) var isLoading = false

    /// 时间轴是否展开（UI 状态，放在 VM 里是为了跨刷新保持住用户的选择）。
    var isTimelineExpanded = true

    /// 计算本屏文案用的"今天"（一次算定，避免同一屏跨午夜不一致）。
    private(set) var today: DateOnly = DateOnly(Date())

    private var environment: AppEnvironment?
    private var truncatedSubscriptionIDs: Set<UUID> = []

    // MARK: - 组装

    /// 注入依赖（幂等，可重复调用）。
    @MainActor
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// 读取并组装。
    ///
    /// - Parameter explicitToday: 今天（默认设备本地自然日；测试注入固定日）。
    @MainActor
    func load(today explicitToday: DateOnly? = nil) {
        guard let environment else { return }
        let referenceDay = explicitToday ?? DateOnly(Date())
        today = referenceDay
        isLoading = true
        defer { isLoading = false }

        do {
            let subscriptions = try environment.subscription.subscriptions()
            let snapshots = SubscriptionMapper.snapshots(subscriptions)

            groups = SubscriptionListViewModel.makeGroups(
                subscriptions: subscriptions,
                today: referenceDay,
                truncated: truncatedSubscriptionIDs
            )
            overview = SubscriptionListViewModel.makeOverview(snapshots: snapshots, today: referenceDay)
            errorMessage = nil
        } catch {
            groups = []
            overview = .empty
            errorMessage = "订阅数据读取失败：\(error.localizedDescription)"
        }
    }

    /// 下拉刷新：**用户显式意图**，绕过 60s 节流扫一次，再重新读取。
    @MainActor
    func refresh() async {
        guard let environment else { return }
        let report = environment.sweep.sweep(force: true)
        lastSweepReport = report
        truncatedSubscriptionIDs = Set(report.truncatedSubscriptionIDs)
        load()
    }

    // MARK: - 用户动作

    /// 行内左滑「暂停 / 恢复」。返回要展示的 Toast 文案。
    @MainActor
    func togglePause(_ row: RowModel) -> String? {
        guard let environment else { return nil }
        do {
            switch row.status {
            case .active:
                try environment.subscription.pause(id: row.id)
                load(today: today)
                return "已暂停「\(row.name)」"
            case .paused:
                try environment.subscription.resume(id: row.id, today: today)
                load(today: today)
                return "已恢复「\(row.name)」"
            case .cancelled:
                return nil
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 行内左滑「删除」。返回要展示的 Toast 文案。
    @MainActor
    func delete(_ row: RowModel) -> String? {
        guard let environment else { return nil }
        do {
            try environment.subscription.delete(id: row.id)
            load(today: today)
            return "已删除「\(row.name)」，历史账目会保留"
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 「已续费」（R-SUB-6）：生成这一期账目并推进周期。
    @MainActor
    func markRenewed(_ row: RowModel) -> String? {
        guard let environment else { return nil }
        do {
            let result = try environment.subscription.markRenewed(id: row.id, today: today)
            load(today: today)
            guard let result else { return "这个订阅会自动扣费，不需要手动续费" }
            return result.didGenerate ? "已记下这一期续费" : "已推进到下一期"
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 清掉错误横幅（用户看过之后）。
    @MainActor
    func dismissError() {
        errorMessage = nil
    }

    /// 记住这次扫描结果（进 Tab 的那次扫描不经过 `refresh`）。
    @MainActor
    func record(_ report: SweepReport) {
        lastSweepReport = report
        truncatedSubscriptionIDs = Set(report.truncatedSubscriptionIDs)
    }

    // MARK: - 纯函数：分组

    /// 三组切分（PRD 4.5）：生效中按 `nextBillingDay` 升序，空组隐藏。
    static func makeGroups(
        subscriptions: [Subscription],
        today: DateOnly,
        truncated: Set<UUID> = []
    ) -> [GroupModel] {
        var active: [RowModel] = []
        var paused: [RowModel] = []
        var cancelled: [RowModel] = []

        for subscription in subscriptions {
            let row = makeRow(
                subscription,
                today: today,
                isTruncated: truncated.contains(subscription.id)
            )
            switch row.status {
            case .active: active.append(row)
            case .paused: paused.append(row)
            case .cancelled: cancelled.append(row)
            }
        }

        // 生效中：下次扣费日升序（同日按名称，保证顺序稳定）
        active.sort { lhs, rhs in
            let left = lhs.nextBillingDayKey == 0 ? Int32.max : lhs.nextBillingDayKey
            let right = rhs.nextBillingDayKey == 0 ? Int32.max : rhs.nextBillingDayKey
            if left != right { return left < right }
            return lhs.name < rhs.name
        }
        // 已暂停 / 已取消：没有"即将扣费"的概念，按名称排即可（分组内不跳动）
        paused.sort { $0.name < $1.name }
        cancelled.sort { $0.name < $1.name }

        var groups: [GroupModel] = []
        if !active.isEmpty { groups.append(GroupModel(status: .active, rows: active)) }
        if !paused.isEmpty { groups.append(GroupModel(status: .paused, rows: paused)) }
        if !cancelled.isEmpty { groups.append(GroupModel(status: .cancelled, rows: cancelled)) }
        return groups
    }

    // MARK: - 纯函数：总览

    /// 总览卡（PRD 4.4）：每月固定支出 / 年度总成本 / 未来 30 天。
    static func makeOverview(snapshots: [SubscriptionSnapshot], today: DateOnly) -> OverviewModel {
        let upcoming = SubscriptionOverview.upcoming(snapshots, today: today)
        return OverviewModel(
            monthlyFixedCost: SubscriptionOverview.monthlyFixedCost(snapshots),
            yearlyCost: SubscriptionOverview.yearlyCost(snapshots),
            upcoming: upcoming,
            upcomingTotal: SubscriptionOverview.upcomingTotal(upcoming)
        )
    }

    // MARK: - 纯函数：行文案

    /// 单行展示数据。
    static func makeRow(
        _ subscription: Subscription,
        today: DateOnly,
        isTruncated: Bool = false
    ) -> RowModel {
        let trimmedIcon = subscription.iconName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trialEnd = subscription.trialEndDate
        let isTrial = trialEnd.map { $0 > today } ?? false
        var trialText: String?
        if isTrial, let trialEnd {
            trialText = "试用中，\(dayDistance(from: today, to: trialEnd)) 天后开始扣费"
        }

        return RowModel(
            id: subscription.id,
            name: subscription.displayName,
            iconName: trimmedIcon.isEmpty ? "arrow.triangle.2.circlepath" : trimmedIcon,
            colorHex: subscription.colorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? PresetCatalog.paletteHex(at: 4)
                : subscription.colorHex,
            amountPerCycleText: subscription.pricePerCycleText,
            nextBillingText: nextBillingText(for: subscription, today: today),
            nextBillingDayKey: subscription.nextBillingDay,
            status: subscription.status,
            autoRenew: subscription.autoRenew,
            isTrial: isTrial,
            trialText: trialText,
            isAwaitingRenewal: subscription.isAwaitingRenewal(on: today),
            isTruncated: isTruncated
        )
    }

    /// 下次扣费文案："11月25日（5天后）" / "（今天）" / "（已逾期 2 天）"。
    static func nextBillingText(for subscription: Subscription, today: DateOnly) -> String {
        guard let day = subscription.nextBillingDate else {
            return subscription.status == .cancelled ? "已取消" : "没有下次扣费日"
        }
        let distance = dayDistance(from: today, to: day)
        if distance == 0 { return "\(day.displayString)（今天）" }
        if distance > 0 { return "\(day.displayString)（\(distance)天后）" }
        return "\(day.displayString)（已逾期 \(-distance) 天）"
    }

    /// 两个自然日相差多少天（正数 = `to` 在未来）。
    static func dayDistance(from: DateOnly, to: DateOnly) -> Int {
        DateOnly.daysFromCivil(year: to.year, month: to.month, day: to.day)
            - DateOnly.daysFromCivil(year: from.year, month: from.month, day: from.day)
    }
}
