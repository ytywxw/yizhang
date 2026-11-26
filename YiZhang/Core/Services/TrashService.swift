//
//  TrashService.swift
//  一账 / Core / Services
//
//  职责：「最近删除」的只读查询 + 三种销毁 + 恢复（V1.1 / PRD §6）。
//
//  分层位置：`View → ViewModel → TrashService → LedgerWriter / SubscriptionService → SwiftData`。
//  本层允许 `import SwiftData`（要引用 `@Model` 类型），禁止 `import SwiftUI`，
//  也**禁止自己调 `context.save()`**——提交一律经 `LedgerWriter`（A3 铁律）。
//
//  ## 为什么需要一个独立服务，而不是让设置页直接查
//
//  "最近删除"看起来只是"把 `deletedAt != nil` 的账目列出来"，实际上有三条容易做错的语义：
//  ① **保留期**：30 天按自然日算，不是按 720 小时；过期是**物理删除**（PRD 6.2），
//     不是隐藏——隐藏等于数据永久留库却永不可达，既违背对用户的承诺也白占空间；
//  ② **容量兜底**：500 条上限，超出按 `deletedAt` 从最旧开始物理删除
//     （防的是"误删全库"这种极端场景）；
//  ③ **恢复订阅账目要回退抑制表**：`unsuppress(cycleKey:)`，否则该期一旦被硬删就再也回不来
//     （PRD 6.2 最后一条 / 6.3-1）。
//  这三条都必须只有一份实现，所以收敛到本服务。
//
//  ## 为什么查询一律用 `deletedDay` 整数谓词
//
//  iOS 17 的 `#Predicate` 对 `Optional<Date>` 的非等值比较（`!= nil` / `>` / `<`）
//  有已知崩溃面（见 `QueryDescriptors` 顶部注释）。`deletedAt` 是 `Date?`，
//  拿它进谓词就是给线上留一颗随机崩溃的雷。因此：
//  - 是否在回收站 → `deletedDay > 0`
//  - 是否过期 → `deletedDay < 截止日键`
//  `deletedAt` 只用于**内存里**的二次排序，永不进谓词。
//
//  ## 为什么本文件自带 FetchDescriptor
//
//  `QueryDescriptors` 是"账目/账户/分类/订阅/待办"这些**既有查询域**的唯一来源，
//  改动它会牵动 484 个既有测试的假设。回收站是本批新建的独立查询域，
//  两个谓词（`deletedDay > 0`、`deletedDay < 截止`）与保留期语义强绑定，
//  放在本文件反而更可读。
//

import Foundation
import SwiftData

// MARK: - 错误

/// 恢复失败的原因。
///
/// 刻意只有一个 case：真正会让用户看见的失败只有"这笔账已经不在了"
/// （被 30 天清理或被另一处彻底删除）。其余路径都按"静默跳过"设计——
/// 救急页面弹错误弹窗只会让用户更慌。
enum TrashError: LocalizedError, Equatable {
    /// 目标账目不存在（可能已被清理）。
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .entryNotFound: return "这笔账已不存在"
        }
    }
}

// MARK: - 值类型

/// 「最近删除」列表里的一行。
///
/// 纯值类型：列表滚动时不持有 `@Model`，避免把一个长生命周期 view 钉在某个 context 上。
struct TrashItem: Identifiable, Sendable, Hashable {

    /// 账目 id。
    let id: UUID

    /// 原发生日 `yyyyMMdd`（行内显示「原日期 11月1日」）。
    let occurredDay: Int32

    /// 金额。
    let amount: Money

    /// 备注。
    let note: String

    /// 分类 id（分类已被删则为 nil，UI 显示"无分类"）。
    let categoryID: UUID?

    /// 账户 id。
    let accountID: UUID?

    /// `EntrySource` 的 raw 值（来源徽章用）。
    let sourceRaw: String

    /// `EntryConfirmation` 的 raw 值（PRD 6.3-5：恢复后保持原状态）。
    let confirmRaw: String

    /// 删除标记（`deletedAt` + `deletedDay` 同源，见 `LedgerWriter` 的两个唯一入口）。
    ///
    /// 这里刻意存一个 `DeletionMark` 而不是两个独立字段：`TrashItem` 是软删记录的快照投影，
    /// 而"两列脱节"的记录在类型层面就不该存在（风险 R1）。
    /// `deletedAt` / `deletedDay` 作为只读派生属性对外暴露，UI 与排序的调用点写法不变。
    let deletion: DeletionMark

    /// 剩余可恢复天数（0 表示即将被清理）。
    let remainingDays: Int

    /// `EntryType` 的 raw 值（V1.1 / 回收站行内金额配色用）。
    ///
    /// 为什么回收站也需要类型：同一条「25.00」在支出与收入里的含义完全相反，
    /// 只靠分类名去猜（分类自己带类型）在"分类已被删除"时就没有答案了。
    let typeRaw: String

    /// 源对象 id（订阅 / 待办）。
    ///
    /// 只用于判断**源对象是否已被删除**（PRD 6.3-4：徽章显示「订阅已删除」/「待办已删除」）。
    /// 它不参与恢复：软删只动删除标记两列，源对象是否存在都不影响恢复这笔账。
    let sourceRefID: UUID?

    init(
        id: UUID,
        occurredDay: Int32,
        amount: Money,
        note: String,
        categoryID: UUID?,
        accountID: UUID?,
        sourceRaw: String,
        confirmRaw: String,
        deletion: DeletionMark,
        remainingDays: Int,
        typeRaw: String = EntryType.expense.raw,
        sourceRefID: UUID? = nil
    ) {
        self.id = id
        self.occurredDay = occurredDay
        self.amount = amount
        self.note = note
        self.categoryID = categoryID
        self.accountID = accountID
        self.sourceRaw = sourceRaw
        self.confirmRaw = confirmRaw
        self.deletion = deletion
        self.remainingDays = remainingDays
        self.typeRaw = typeRaw
        self.sourceRefID = sourceRefID
    }

    /// 删除日 `yyyyMMdd`（分组键，恒 > 0）。
    var deletedDay: Int32 { deletion.day }

    /// 删除时刻（组内二次排序用）。
    var deletedAt: Date { deletion.at }

    /// 原发生日。
    var occurredDate: DateOnly { DateOnly(key: occurredDay) }

    /// 删除日。
    var deletedDate: DateOnly { DateOnly(key: deletedDay) }

    /// 来源（未知 raw 按手动处理）。
    var source: EntrySource { EntrySource(raw: sourceRaw) ?? .manual }

    /// 账目类型（未知 raw 按支出处理，理由同 `EntryType` 的其它调用点）。
    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

    /// 是否待确认（恢复后仍回到 pending，PRD 6.3-5）。
    var isPending: Bool { confirmRaw == EntryConfirmation.pending.raw }

    /// 是否即将过期（1 天内），UI 用红色提示。
    var isExpiringSoon: Bool { remainingDays <= 1 }
}

/// 按删除日分的一组。
struct TrashDayGroup: Identifiable, Sendable, Hashable {

    /// 删除日 `yyyyMMdd`。
    let day: Int32

    /// 当天的删除项（按 `deletedAt` 倒序）。
    let items: [TrashItem]

    var id: Int32 { day }

    /// 这一组包含的条数。
    var count: Int { items.count }

    init(day: Int32, items: [TrashItem]) {
        self.day = day
        self.items = items
    }
}

// MARK: - 服务

/// 最近删除服务。
@MainActor
final class TrashService {

    /// 保留期（天）。PRD 6.2：按 `deletedAt` 与今天相差的**自然日数**，`> 30` 即过期。
    ///
    /// 与 PRD §8 既有承诺一致，不新造数字。
    static let retentionDays = 30

    /// 容量上限（条）。超出按 `deletedAt` 从最旧开始物理删除。
    ///
    /// 兜底的是"误删全库"这种极端场景：500 条已经远超正常用户 30 天内的删除总量，
    /// 真撞到说明发生了批量误操作，此时保留最近 500 条比"全都留着"更有用。
    static let capacity = 500

    private let writer: LedgerWriter

    /// 订阅服务：恢复订阅来源账目时要回退抑制表（`unsuppress(cycleKey:of:)`）。
    ///
    /// 为什么是可选：`nil` 只用于"不关心抑制表"的单元测试。
    /// 生产路径由 `AppEnvironment` 必传——传 nil 会让 PRD 6.3-1 的保证失效。
    private let subscription: SubscriptionService?

    /// 写入提交后的回调（由 `AppEnvironment` 接到 `bumpDataVersion()`）。
    var onDidCommit: (() -> Void)?

    init(
        writer: LedgerWriter,
        subscription: SubscriptionService? = nil,
        onDidCommit: (() -> Void)? = nil
    ) {
        self.writer = writer
        self.subscription = subscription
        self.onDidCommit = onDidCommit
    }

    // MARK: - 读

    /// 回收站条数（设置页「最近删除 3」行尾数字）。
    func count() throws -> Int {
        try writer.count(TrashService.softDeletedDescriptor())
    }

    /// 按删除日倒序分组；同一天内按删除时刻倒序（PRD 6.3-6：固定排序，不提供排序器）。
    ///
    /// 排序的稳定性与 `TemplateService.all()` 同理：同一时刻删除的多条记录
    /// 用 `id` 做第三级键兜底，避免两次 `fetch` 之后组内顺序悄悄变化。
    ///
    /// - Parameter today: 今天的自然日（剩余天数与过期判定都以它为基准）。
    /// - Returns: 分组列表；回收站为空时返回空数组（不用 nil 表示空，避免 UI 写双层判断）。
    func groups(today: DateOnly) throws -> [TrashDayGroup] {
        let entries = try writer.fetch(TrashService.softDeletedDescriptor())
        guard !entries.isEmpty else { return [] }

        var buckets: [Int32: [TrashItem]] = [:]
        for entry in entries {
            // `deletedDay > 0` 已在谓词里过滤，这里再挡一次是为了防御
            // "历史数据里 deletedAt 有值但 deletedDay 为 0"的脏记录（风险 R1 的遗留物）：
            // 它们不该出现在回收站，也不该被当成有效账目统计。
            guard let moment = entry.deletedAt, entry.deletedDay > 0 else { continue }
            let item = TrashItem(
                id: entry.id,
                occurredDay: entry.occurredDay,
                amount: Money(cents: entry.amount),
                note: entry.note,
                categoryID: entry.category?.id,
                accountID: entry.account?.id,
                sourceRaw: entry.sourceRaw,
                confirmRaw: entry.confirmRaw,
                deletion: DeletionMark(at: moment, day: entry.deletedDay),
                remainingDays: TrashService.remainingDays(deletedDay: entry.deletedDay, today: today),
                typeRaw: entry.typeRaw,
                sourceRefID: entry.sourceRefID
            )
            buckets[entry.deletedDay, default: []].append(item)
        }

        return buckets
            .map { day, items in
                TrashDayGroup(day: day, items: TrashService.sorted(items))
            }
            .sorted { lhs, rhs in lhs.day > rhs.day }
    }

    /// 全部删除项的扁平列表（导出/统计类需求用；顺序与 `groups` 一致）。
    func items(today: DateOnly) throws -> [TrashItem] {
        try groups(today: today).flatMap(\.items)
    }

    // MARK: - 恢复

    /// 恢复一条账目（PRD 6.1 / 6.2）。
    ///
    /// 只做两件事，且顺序不能反：
    /// ① `writer.unmarkDeleted` —— 把 `deletedAt` 与 `deletedDay` **一起**归零
    ///    （唯一入口，见 `LedgerWriter`；只把 `deletedAt` 清空会留下 `deletedDay`，
    ///    于是这笔账同时出现在账本和回收站里，风险 R1）；
    /// ② 若是订阅来源，回退抑制表 —— 不回退的话，这一期一旦被硬删就再也回不来。
    ///
    /// **不需要写回任何业务字段**：软删只改了两列，其余字段（含 `confirmRaw`、
    /// `createdAt`、`sourceCycleKey`）从未被修改，因此"恢复后与删除前完全一致"
    /// 是由软删的实现方式保证的，而不是靠这里逐个字段补齐。
    ///
    /// - Parameters:
    ///   - entryID: 账目 id。
    ///   - moment: 恢复时刻（写入 `updatedAt`）。
    /// - Throws: `TrashError.entryNotFound`（账目已被清理）。
    func restore(_ entryID: UUID, at moment: Date = Date()) throws {
        guard let entry = try writer.entry(id: entryID) else { throw TrashError.entryNotFound }

        // 已经是未删除状态：幂等返回，不重复提交（「恢复」按钮可能被连点两次）。
        guard entry.deletedAt != nil || entry.deletedDay > 0 else { return }

        let sourceRaw = entry.sourceRaw
        let sourceRefID = entry.sourceRefID
        let cycleKey = entry.sourceCycleKey

        try writer.unmarkDeleted(entry, at: moment)

        if sourceRaw == EntrySource.subscription.raw,
           let subscriptionID = sourceRefID,
           let cycleKey, !cycleKey.isEmpty {
            // 订阅已被删除 / 抑制表里本来就没有这一期 → 静默跳过（PRD 6.3-4：不报错）
            _ = try? subscription?.unsuppress(cycleKey: cycleKey, of: subscriptionID)
        }

        onDidCommit?()
    }

    // MARK: - 销毁

    /// 彻底删除一条（`LedgerWriter.hardDelete`，不可恢复）。
    ///
    /// - Parameter entryID: 账目 id。
    func purge(_ entryID: UUID) throws {
        guard try writer.hardDelete(id: entryID) else { return }
        onDidCommit?()
    }

    /// 彻底删除回收站里的全部（页面底部「全部彻底删除」，UI 侧已二次确认）。
    ///
    /// 逐条 `hardDelete` 而不是一条批量语句：`hardDelete` 是**唯一**的硬删入口
    /// （R8 要求订阅 B 分支也走它），绕过它另写一条批量删除等于把"账目只能被
    /// `LedgerWriter` 删除"这条铁律开出第二个口子。回收站上限 500 条，逐条提交可接受。
    ///
    /// - Returns: 实际删除的条数。
    @discardableResult
    func purgeAll() throws -> Int {
        let entries = try writer.fetch(TrashService.softDeletedDescriptor())
        guard !entries.isEmpty else { return 0 }

        var removed = 0
        for entry in entries {
            if try writer.hardDelete(id: entry.id) {
                removed += 1
            }
        }
        if removed > 0 {
            onDidCommit?()
        }
        return removed
    }

    /// 清理过期项与超额项（冷启动 + 每次软删后调用，PRD 6.2）。
    ///
    /// 两件事一起做是有意的：容量兜底只有在"回收站已经很大"时才触发，
    /// 而"回收站很大"与"有一批过期项"几乎总是同时发生；分两个方法只会让调用方漏一个。
    ///
    /// - Parameter today: 今天的自然日。
    /// - Returns: 实际物理删除的条数（过期 + 超额）。
    @discardableResult
    func purgeExpired(today: DateOnly) throws -> Int {
        var removed = try purgeExpiredOnly(today: today)
        removed += try enforceCapacity()
        if removed > 0 {
            onDidCommit?()
        }
        return removed
    }

    // MARK: - 内部

    /// 只清过期项。
    private func purgeExpiredOnly(today: DateOnly) throws -> Int {
        let cutoff = today.adding(days: -TrashService.retentionDays).key
        let expired = try writer.fetch(TrashService.softDeletedBefore(cutoff))

        var removed = 0
        for entry in expired {
            if try writer.hardDelete(id: entry.id) {
                removed += 1
            }
        }
        return removed
    }

    /// 超出容量时，从最旧的删除开始清。
    private func enforceCapacity() throws -> Int {
        let entries = try writer.fetch(TrashService.softDeletedDescriptor())
        guard entries.count > TrashService.capacity else { return 0 }

        // 最旧在前：删除时刻相同则用 id 兜底，保证每次跑的结果一致
        let ordered = entries.sorted { lhs, rhs in
            let left = lhs.deletedAt ?? Date(timeIntervalSince1970: 0)
            let right = rhs.deletedAt ?? Date(timeIntervalSince1970: 0)
            if left != right { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let overflow = ordered.count - TrashService.capacity
        var removed = 0
        for entry in ordered.prefix(overflow) {
            if try writer.hardDelete(id: entry.id) {
                removed += 1
            }
        }
        return removed
    }

    /// 剩余可恢复天数（`retentionDays` 减去已过的自然日数，夹到 0）。
    ///
    /// 用纯整数日差（`DateOnly.daysFromCivil`）而不是时间间隔：
    /// "剩余 12 天"必须是自然日口径，用 86400 秒相除会在跨夏令时时差一天。
    private static func remainingDays(deletedDay: Int32, today: DateOnly) -> Int {
        let deleted = DateOnly(key: deletedDay)
        guard deleted.isValid, today.isValid else { return 0 }
        let elapsed = DateOnly.daysFromCivil(year: today.year, month: today.month, day: today.day)
            - DateOnly.daysFromCivil(year: deleted.year, month: deleted.month, day: deleted.day)
        return max(TrashService.retentionDays - elapsed, 0)
    }

    /// 组内排序：删除时刻倒序 → id 升序。
    private static func sorted(_ items: [TrashItem]) -> [TrashItem] {
        items.sorted { lhs, rhs in
            if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt > rhs.deletedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 回收站全量查询（整数谓词，`Optional<Date>` 不进谓词）。
    private static func softDeletedDescriptor() -> FetchDescriptor<LedgerEntry> {
        FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in entry.deletedDay > 0 }
        )
    }

    /// 早于截止日键的软删记录（`deletedDay < cutoff`）。
    ///
    /// `cutoff` 是"今天 - 30 天"的日键，于是 `deletedDay < cutoff` 恰好等价于
    /// "删除日距今超过 30 个自然日"，与 PRD 6.2 的 `> 30` 口径一致。
    private static func softDeletedBefore(_ cutoff: Int32) -> FetchDescriptor<LedgerEntry> {
        FetchDescriptor<LedgerEntry>(
            predicate: #Predicate<LedgerEntry> { entry in
                entry.deletedDay > 0 && entry.deletedDay < cutoff
            }
        )
    }
}
