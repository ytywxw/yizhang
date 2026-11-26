//
//  TrashViewModel.swift
//  一账 / Features / Settings
//
//  职责：「最近删除」页的全部业务（V1.1 / PRD §6）——分组展示 + 恢复 + 彻底删除。
//
//  ## 三条必须落在这里、不能散到视图里的判断
//
//  ① **分组标题按自然日算**：`今天` / `昨天` / `11月18日`。判定用 `DateOnly` 的
//     整数日键相等与 `adding(days: -1)`，**不许用 `Calendar` 拼字符串**——
//     `Calendar` 会带上用户时区与"是否 24 小时制"这些变量，跨时区/夏令时会出现
//     "明明是周一的账，显示成周日"。标题因此在 VM 里算好（`Group.title`），
//     视图只负责渲染，不碰日期数学。
//  ② **不排序**：`TrashService.groups(today:)` 已经按删除日倒序 + 组内删除时刻倒序 +
//     `id` 兜底排好（`TrashService.sorted`）。本类与视图**一律不再排一次**——
//     两个排序点迟早会分叉，而"顺序莫名其妙的回收站"是用户最先投诉的那类问题。
//  ③ **"源对象已删除"只影响徽章，不影响恢复**（PRD 6.3-4）：这里只是把
//     "订阅 / 待办是否还在"查出来给徽章用。恢复走 `TrashService.restore`，
//     它从不读源对象，所以订阅没了也能把账恢复回来。
//
//  ## 为什么行模型要重建一层，而不是直接渲染 `TrashItem`
//
//  `TrashItem` 只有 `categoryID`。分类名、图标、颜色都是**另一个实体**的属性，
//  而列表是滚动渲染的，不能在 `body` 里按行去 fetch（500 行 = 500 次查询）。
//  所以在 `reload()` 里一次取全量分类建成字典，再投影成 `Row`。
//

import Foundation
import Observation

/// 最近删除页的 ViewModel。
@Observable
@MainActor
final class TrashViewModel {

    // MARK: - 行

    /// 列表里的一行：`TrashItem` + 分类的展示信息。
    struct Row: Identifiable, Hashable {

        /// 原始删除项（恢复/彻底删除都用它的 `id`）。
        let item: TrashItem
        /// 分类名（分类已被删时是「无分类」）。
        let categoryName: String
        /// 分类图标（分类已被删时是问号）。
        let iconName: String
        /// 分类色（分类已被删时用兜底色）。
        let colorHex: String
        /// 源对象（订阅 / 待办）是否已被删除（PRD 6.3-4）。
        let isSourceDeleted: Bool

        var id: UUID { item.id }

        var amount: Money { item.amount }

        var note: String { item.note }

        var type: EntryType { item.type }

        var occurredDate: DateOnly { item.occurredDate }

        /// 剩余可恢复天数（右尾「剩余 12 天」）。
        var remainingDays: Int { item.remainingDays }

        /// 是否 1 天内过期（UI 用红色提示）。
        var isExpiringSoon: Bool { item.isExpiringSoon }

        /// 来源徽章文字（手动记账为空串 = 不显示徽章）。
        ///
        /// 两种形态：源对象还在 → 「订阅」/「待办」；源对象已被删 → 「订阅已删除」/「待办已删除」。
        /// 后者只是告诉用户"这条账的来历已经找不到了"，恢复按钮依然可用。
        var sourceBadgeText: String {
            guard item.source.needsBadge else { return "" }
            let name = item.source.displayName
            return isSourceDeleted ? "\(name)已删除" : name
        }

        /// 整行的无障碍朗读文本（把散在三个视觉层里的信息合成一句）。
        var accessibilityText: String {
            var parts: [String] = [categoryName]
            if !note.isEmpty { parts.append(note) }
            parts.append(item.type.isIncome ? "收入\(amount.accessibilityText)" : amount.accessibilityText)
            parts.append("原日期\(occurredDate.displayString)")
            if !sourceBadgeText.isEmpty { parts.append("来自\(sourceBadgeText)") }
            if isExpiringSoon {
                parts.append("即将清理")
            } else {
                parts.append("剩余 \(remainingDays) 天")
            }
            if item.isPending { parts.append("待确认") }
            return parts.joined(separator: "，")
        }
    }

    /// 一个删除日的分组。
    struct Group: Identifiable, Hashable {

        /// 删除日 `yyyyMMdd`。
        let day: Int32
        /// 组标题：`今天` / `昨天` / `11月18日`（在 VM 里算好，视图不碰日期）。
        let title: String
        /// 当天删除的账目（顺序已由 `TrashService` 定好，不得再排）。
        let rows: [Row]

        var id: Int32 { day }

        var count: Int { rows.count }
    }

    // MARK: - 状态

    /// 按删除日倒序的分组（空数组 = 回收站是空的，不用 nil 表示空）。
    private(set) var groups: [Group] = []

    /// 回收站总条数（= 各分组条目数之和，与列表显示同源）。
    private(set) var count: Int = 0

    /// 读失败的原因（写失败走 Toast，见视图层）。
    private(set) var errorMessage: String?

    /// 是否已经取过一次数据（首帧用骨架屏）。
    private(set) var isLoaded = false

    /// `nil` 表示还没 `attach`（预览/测试里先构造再挂载）。
    @ObservationIgnored
    private var environment: AppEnvironment?

    /// 今天的自然日来源。
    ///
    /// 默认 `DateOnly(Date())`；测试注入固定日期，于是"剩余 12 天"这类断言不依赖跑测试的那天。
    @ObservationIgnored
    private let todayProvider: () -> DateOnly

    init(todayProvider: @escaping () -> DateOnly = { DateOnly(Date()) }) {
        self.todayProvider = todayProvider
    }

    // MARK: - 加载

    /// 挂载依赖并立刻加载一次。
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        reload()
    }

    /// 重新读取回收站。
    ///
    /// 读失败时**清空列表并把原因写进 `errorMessage`**，而不是保留上一份快照：
    /// 回收站是"用户来找回东西"的页面，显示一份可能是旧状态的列表比显示错误更危险
    /// （用户看到"还有 3 条"却点不进去）。
    func reload() {
        guard let environment else { return }
        do {
            let today = todayProvider()
            let rawGroups = try environment.trash.groups(today: today)
            let styles = try categoryStyles(environment)
            let sources = try liveSourceIDs(environment)

            groups = rawGroups.map { group in
                Group(
                    day: group.day,
                    title: Self.title(forDay: group.day, today: today),
                    rows: group.items.map { item in
                        makeRow(item, styles: styles, sources: sources)
                    }
                )
            }
            count = groups.reduce(0) { $0 + $1.count }
            errorMessage = nil
        } catch {
            groups = []
            count = 0
            errorMessage = "最近删除读取失败：\(error.localizedDescription)。退出这一页再进来可以重试。"
        }
        isLoaded = true
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 恢复

    /// 恢复一条账目（PRD 6.1）。
    ///
    /// 恢复成功后立刻重读：条目要马上从列表消失，且分组为空时整组随之消失。
    /// 订阅来源的抑制表回退由 `TrashService.restore` 负责，这里不重复做——
    /// 两处都做会在"抑制表里本来就没有这一期"时多一次无意义的写。
    ///
    /// - Throws: `TrashError.entryNotFound`（账目已被清理），或底层写入失败。
    func restore(id: UUID) throws {
        guard let environment else { throw TrashViewError.notReady }
        try environment.trash.restore(id)
        reload()
    }

    // MARK: - 销毁

    /// 彻底删除一条（不可恢复）。
    func purge(id: UUID) throws {
        guard let environment else { throw TrashViewError.notReady }
        try environment.trash.purge(id)
        reload()
    }

    /// 彻底删除全部（调用方已做二次确认）。
    ///
    /// - Returns: 实际删除的条数。
    @discardableResult
    func purgeAll() throws -> Int {
        guard let environment else { throw TrashViewError.notReady }
        let removed = try environment.trash.purgeAll()
        reload()
        return removed
    }

    // MARK: - 私有

    /// 分类展示信息字典（一次取全量，避免按行 fetch）。
    private struct CategoryStyle: Hashable {
        let name: String
        let iconName: String
        let colorHex: String
    }

    /// 仍然存在的源对象 id 集合。
    private struct LiveSources {
        let subscriptions: Set<UUID>
        let todos: Set<UUID>
    }

    private func makeRow(
        _ item: TrashItem,
        styles: [UUID: CategoryStyle],
        sources: LiveSources
    ) -> Row {
        let style = item.categoryID.flatMap { styles[$0] }
        return Row(
            item: item,
            categoryName: style?.name ?? "无分类",
            iconName: style?.iconName ?? "questionmark.circle",
            colorHex: style?.colorHex ?? PresetCatalog.fallbackColorHex,
            isSourceDeleted: isSourceDeleted(item, sources: sources)
        )
    }

    /// 源对象是否已被删除。
    ///
    /// 判据必须是**两个**：`sourceRefID` 存在（老数据可能缺）+ 源对象确实查不到。
    /// 只判断前者会把"缺 id 的历史账目"误标成已删除；只判断后者会误伤手动记账。
    private func isSourceDeleted(_ item: TrashItem, sources: LiveSources) -> Bool {
        guard item.source.needsBadge, let referenceID = item.sourceRefID else { return false }
        switch item.source {
        case .manual:
            return false
        case .subscription:
            return !sources.subscriptions.contains(referenceID)
        case .todo:
            return !sources.todos.contains(referenceID)
        }
    }

    private func categoryStyles(_ environment: AppEnvironment) throws -> [UUID: CategoryStyle] {
        let expense = try environment.readContext.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: true)
        )
        let income = try environment.readContext.fetch(
            QueryDescriptors.categories(of: .income, includeHidden: true)
        )
        var styles: [UUID: CategoryStyle] = [:]
        for category in expense + income {
            styles[category.id] = CategoryStyle(
                name: category.displayName,
                iconName: category.displayIconName,
                colorHex: category.colorHex
            )
        }
        return styles
    }

    private func liveSourceIDs(_ environment: AppEnvironment) throws -> LiveSources {
        let subscriptions = try environment.readContext.fetch(QueryDescriptors.allSubscriptions())
        let todos = try environment.readContext.fetch(QueryDescriptors.allTodos())
        return LiveSources(
            subscriptions: Set(subscriptions.map(\.id)),
            todos: Set(todos.map(\.id))
        )
    }

    /// 分组标题：`今天` / `昨天` / `11月18日`。
    ///
    /// 纯整数比较（`DateOnly` 的 `==` 与 `adding(days: -1)`），不走 `Calendar`：
    /// 这里只需要"相差几个自然日"，而 `DateOnly` 的两个日键相减就是这个数。
    static func title(forDay day: Int32, today: DateOnly) -> String {
        let date = DateOnly(key: day)
        guard date.isValid, today.isValid else { return "未知日期" }
        if date == today { return "今天" }
        if date == today.adding(days: -1) { return "昨天" }
        return date.displayString
    }
}

// MARK: - 错误

/// 回收站页的错误。
///
/// 只有 `notReady` 一个 case：其余失败原因（账目已被清理、写库失败）都由
/// `TrashService` / `LocalizedError` 原样抛出，这里不再包一层——
/// 包一层只会让用户看到"操作失败：操作失败"。
enum TrashViewError: LocalizedError, Hashable {
    /// 依赖还没挂上（正常不会发生：视图在 `task` 里先 `attach`）。
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "数据还没准备好，请稍后再试"
        }
    }
}
