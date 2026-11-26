//
//  LedgerLite.swift
//  一账 / Core / Domain
//
//  职责：给 Domain 层算法用的轻量值类型（架构 §4.2），以及扫描结果的动作描述。
//
//  为什么要有这一层（而不是直接把 `@Model` 传进 Domain）：
//  1. `MonthlyStatsCalculator` 需要一年数据，传 `@Model` 数组会把整行（note / tags / 关系）
//     全部 materialize；传 `LedgerLite`（7 个标量）内存友好；
//  2. **单元测试不需要 `ModelContainer`**——纯 struct 数组即跑，测试速度提升一个量级；
//  3. `SweepPlanner` 输入 `SubscriptionSnapshot`、输出 `[SweepAction]`，
//     于是 R-SUB-3/4/5/7/8 的全部规则可以在 0 个数据库的情况下被完整单测。
//
//  本文件是纯 Swift：不 import SwiftData / SwiftUI。
//  模型 → 轻量 DTO 的一次拷贝由 Service 层负责（本文件刻意不提供该 init）。
//

import Foundation

// MARK: - 账目轻量视图

/// 统计与筛选用的账目轻量视图：只含聚合计算需要的标量。
struct LedgerLite: Hashable, Sendable {

    let id: UUID
    /// 金额（分）。正数；类型由 `typeRaw` 区分。
    let amount: Int64
    /// `EntryType` 的 raw 值。
    let typeRaw: String
    /// `yyyyMMdd`。
    let occurredDay: Int32
    let categoryID: UUID?
    let accountID: UUID?
    /// `EntrySource` 的 raw 值。
    let sourceRaw: String
    /// `EntryConfirmation` 的 raw 值（V1.1）。默认 `confirmed`，
    /// 于是所有既有构造点（含 5 处测试）无需改动即可编译。
    let confirmRaw: String
    /// 删除标记（`nil` = 未删除）。V1.1 起与模型层共用同一个 `DeletionMark`，
    /// 于是"时刻有值、日键为 0"这种半删除态在值类型层面同样不可表达。
    private let deletion: DeletionMark?

    /// 软删除时间（非 nil 表示已删除，统计时必须排除）。
    var deletedAt: Date? { deletion?.at }

    /// 软删除日 `yyyyMMdd`（`0` = 未删除），回收站分组与过期判定用。
    var deletedDay: Int32 { deletion?.day ?? 0 }

    init(
        id: UUID,
        amount: Int64,
        typeRaw: String,
        occurredDay: Int32,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        sourceRaw: String = EntrySource.manual.raw,
        confirmRaw: String = EntryConfirmation.confirmed.raw,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.amount = amount
        self.typeRaw = typeRaw
        self.occurredDay = occurredDay
        self.categoryID = categoryID
        self.accountID = accountID
        self.sourceRaw = sourceRaw
        self.confirmRaw = confirmRaw
        self.deletion = deletedAt.map { DeletionMark(at: $0) }
    }

    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

    var source: EntrySource { EntrySource(raw: sourceRaw) ?? .manual }

    /// 确认状态（未知 raw 按已确认处理，理由同 `LedgerEntry.confirmation`）。
    var confirmation: EntryConfirmation { EntryConfirmation(raw: confirmRaw) ?? .confirmed }

    /// 是否为待确认（仅标记，不影响任何聚合口径）。
    var isPending: Bool { confirmRaw == EntryConfirmation.pending.raw }

    var occurredDate: DateOnly { DateOnly(key: occurredDay) }

    var monthKey: Int32 { occurredDate.monthKey }

    var amountMoney: Money { Money(cents: amount) }

    var isDeleted: Bool { deletedAt != nil }

    /// 计入统计的记录：未软删且金额为正。
    var isCountable: Bool { !isDeleted && amount > 0 }
}

// MARK: - 订阅快照

/// 结算扫描用的订阅快照（14 个标量），由 Service 从 `@Model` 一次性映射而来。
///
/// 它同时承担「幂等键规则」的唯一实现（架构 §3.7 D2）：
/// - `month` / `quarter` / `year` → `yyyy-MM`
/// - `day` / `week` → `d-yyyyMMdd`
///
/// 之所以 day/week 不能用 `yyyy-MM`：E-7 支持"每 45 天""每两周"，
/// 这类周期一个月可能扣两次，用 `yyyy-MM` 会让两次扣费共用同一个幂等键，
/// 第二次被静默丢弃 → 漏账（风险 R5）。
struct SubscriptionSnapshot: Hashable, Sendable {

    let id: UUID
    let name: String
    /// 每期金额（分）。允许 0（E-9：免费订阅不生成账目）。
    let amount: Int64
    /// `SubscriptionStatus` 的 raw 值。
    let statusRaw: String
    let autoRenew: Bool
    /// `yyyyMMdd`；0 表示无（已取消，E-3）。
    let nextBillingDay: Int32
    /// `yyyyMMdd`；0 表示无试用。
    let trialEndDay: Int32
    let cycleUnit: CycleUnit
    let cycleValue: Int
    /// 锚定日 1...31（R-SUB-8）。
    let anchorDay: Int
    /// 提前提醒天数（0 = 当天提醒）。通知规划用它算触发日（T20）。
    let reminderDays: Int
    /// 被用户手动删账后抑制的周期键（R-SUB-DEL A）。
    let suppressedCycles: Set<String>
    let categoryID: UUID?
    let accountID: UUID?

    init(
        id: UUID,
        name: String,
        amount: Int64,
        statusRaw: String = SubscriptionStatus.active.raw,
        autoRenew: Bool = true,
        nextBillingDay: Int32 = 0,
        trialEndDay: Int32 = 0,
        cycleUnit: CycleUnit = .month,
        cycleValue: Int = 1,
        anchorDay: Int = 1,
        reminderDays: Int = 1,
        suppressedCycles: Set<String> = [],
        categoryID: UUID? = nil,
        accountID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.statusRaw = statusRaw
        self.autoRenew = autoRenew
        self.nextBillingDay = nextBillingDay
        self.trialEndDay = trialEndDay
        self.cycleUnit = cycleUnit
        self.cycleValue = cycleValue
        self.anchorDay = anchorDay
        self.reminderDays = reminderDays
        self.suppressedCycles = suppressedCycles
        self.categoryID = categoryID
        self.accountID = accountID
    }

    // MARK: 派生状态

    var status: SubscriptionStatus { SubscriptionStatus(raw: statusRaw) ?? .active }

    var nextBillingDate: DateOnly? { nextBillingDay > 0 ? DateOnly(key: nextBillingDay) : nil }

    var trialEndDate: DateOnly? { trialEndDay > 0 ? DateOnly(key: trialEndDay) : nil }

    /// 是否处于"会生成账目"的基础状态（R-SUB-6：不自动续费的订阅只在用户点"已续费"后生成）。
    var isGeneratingCandidates: Bool { status == .active && autoRenew }

    /// 是否仍在试用期内（E-1：试用期不生成任何账目）。
    func isInTrial(on today: DateOnly) -> Bool { trialEndDay > 0 && today.key < trialEndDay }

    // MARK: 幂等键（架构 §3.7 D2 的唯一实现）

    /// 某次应扣日对应的周期键。
    func cycleKey(for day: DateOnly) -> String {
        switch cycleUnit {
        case .month, .quarter, .year:
            // 自然月类周期：同一自然月只会扣一次，`yyyy-MM` 足够且可读
            return String(format: "%04d-%02d", day.year, day.month)
        case .day, .week:
            // 天/周类周期：同月可能扣多次，必须精确到日，否则幂等键碰撞导致漏账
            return String(format: "d-%04d%02d%02d", day.year, day.month, day.day)
        }
    }

    /// 幂等键 `"<subID>|<cycleKey>"`（架构 §3.3 第 1 层）。
    func uniqueKey(for day: DateOnly) -> String {
        SubscriptionSnapshot.makeUniqueKey(subscriptionID: id, cycleKey: cycleKey(for: day))
    }

    /// 幂等键的唯一拼装实现。
    ///
    /// 所有需要构造订阅幂等键的地方（`LedgerService`、`SweepPlanner`、`SweepCoordinator`）
    /// 都必须走这里或 `uniqueKey(for:)`，**不允许在写入侧再拼一次字符串**——
    /// 拼错一个分隔符就会让幂等整体失效（重复账目）。
    static func makeUniqueKey(subscriptionID: UUID, cycleKey: String) -> String {
        "\(subscriptionID.uuidString)|\(cycleKey)"
    }

    /// 该周期是否已被用户"只删这笔账"抑制（R-SUB-DEL A）。
    func isSuppressed(on day: DateOnly) -> Bool {
        suppressedCycles.contains(cycleKey(for: day))
    }

    // MARK: 推进

    /// 从某个应扣日推进一个周期，保留锚定日（R-SUB-8）。
    func advanced(from day: DateOnly) -> DateOnly {
        CycleAdvancer.advance(from: day, unit: cycleUnit, value: cycleValue, anchorDay: anchorDay)
    }

    /// 从 `nextBillingDay` 推进一个周期；无下次扣费日时返回 nil。
    func advancedNextBilling() -> DateOnly? {
        guard let current = nextBillingDate else { return nil }
        return advanced(from: current)
    }
}

// MARK: - 待写入的账目草稿

/// 账目草稿：写入前的最小描述，由 Service 组装、交给 `LedgerWriter` 落库。
///
/// 与 `LedgerEntry` 分离的意义：`LedgerEntry.init` 在 T06 会被收窄为 `fileprivate`，
/// 于是 Features 层在语法上无法 new 一个账目（A3 铁律的编译期落地），
/// 所有写入都必须经过"草稿 → Writer"这一条通道。
struct EntryDraft: Hashable, Sendable {

    /// `EntryType` 的 raw 值。
    var typeRaw: String = EntryType.expense.raw
    /// 金额（分），业务上必须 > 0。
    var amount: Int64 = 0
    /// `yyyyMMdd`。
    var occurredDay: Int32 = 0
    var categoryID: UUID?
    var accountID: UUID?
    /// 仅 `transfer` 使用。
    var toAccountID: UUID?
    var note: String = ""
    /// `EntrySource` 的 raw 值。
    var sourceRaw: String = EntrySource.manual.raw
    /// 源对象 id（待办 / 订阅）。弱引用：源对象可删，账目保留。
    var sourceRefID: UUID?
    /// 订阅周期键（仅订阅来源）。
    var sourceCycleKey: String?
    /// 幂等键 `"<sourceRefID>|<cycleKey>"`，手动记账为 nil。
    var uniqueKey: String?

    /// `EntryConfirmation` 的 raw 值；`nil` = **由业务层判定**（V1.1 F-SUB-13）。
    ///
    /// 为什么是可选的：草稿是"用户/系统想记的账"，而"这一笔该不该是待确认"是一个业务规则，
    /// 唯一实现位置是 `LedgerService.validated(_:)`（订阅来源 + 应扣日在最近 7 天内 → pending）。
    /// 若这里给 `"confirmed"` 默认值，调用方就永远拿不到"没判定过"这个信息，规则会被复制到各处。
    var confirmRaw: String?

    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

    var source: EntrySource { EntrySource(raw: sourceRaw) ?? .manual }

    var occurredDate: DateOnly { DateOnly(key: occurredDay) }

    var amountMoney: Money { Money(cents: amount) }

    /// 幂等键的另一种写法（与 `sourceCycleUniqueKey` 字段同名语义）。
    var sourceCycleUniqueKey: String? { uniqueKey }
}

// MARK: - 扫描动作（T11）

/// 结算扫描要为某个订阅生成的**一笔**账目：一期 = 一个 action。
///
/// 为什么是"一期一个"而不是"一个订阅一个"：
/// ① 24 笔上限是**笔**级别的约束，只有拆到笔才能精确计数；
/// ② 每期都要带自己的 `occurredDay`（R-SUB-4①：用应扣日，不是今天），合并成一个 action 就得再拆开；
/// ③ `SweepCoordinator` 逐条 `insert`，中途某条幂等命中时其他期不受影响。
struct SweepAction: Hashable, Sendable {

    /// 订阅 id。
    let subscriptionID: UUID
    /// 订阅名（用于生成 `note = "订阅：" + name`，R-SUB-4）。
    let subscriptionName: String
    /// 应扣日 `yyyyMMdd`（**不是今天**）。
    let occurredDay: Int32
    /// 该期金额（分）。
    let amount: Int64
    let categoryID: UUID?
    let accountID: UUID?
    /// 该期的周期键（month/quarter/year → `yyyy-MM`；day/week → `d-yyyyMMdd`）。
    let cycleKey: String
    /// 幂等键 `"<subID>|<cycleKey>"`（由 `SubscriptionSnapshot.makeUniqueKey` 拼装）。
    let uniqueKey: String
    /// 该期之后的下次扣费日。多期补漏时，**最后一条** action 的值就是最终值。
    let nextBillingDayAfter: Int32

    /// `EntryConfirmation` 的 raw 值（V1.1 F-SUB-13）；`nil` = 由 `draft` 的默认行为决定。
    ///
    /// **必须是 `var` 且带默认值**：Swift 会把"带默认值的 `let` 存储属性"从 memberwise
    /// init 里**剔除**，那样这个字段将永远设不进去（编译器不报错，才是最难查的那种 bug）。
    /// 带默认值则既让新字段可选、又不破坏任何既有构造点。
    ///
    /// 值由 `SweepPlanner` 用 `EntryConfirmation.forSubscription(occurredDay:today:)` 算好
    /// 传进来——规则本体只有一处，这里只负责携带，不重新判定。
    var confirmRaw: String? = nil

    /// 转成写入用的草稿（`occurredDay` 用应扣日，来源字段一次写全）。
    var draft: EntryDraft {
        var draft = EntryDraft(
            typeRaw: EntryType.expense.raw,
            amount: amount,
            occurredDay: occurredDay
        )
        draft.categoryID = categoryID
        draft.accountID = accountID
        draft.note = "订阅：\(subscriptionName)"
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = subscriptionID
        draft.sourceCycleKey = cycleKey
        draft.uniqueKey = uniqueKey
        // F-SUB-13：扫描路径同样要带上确认状态（规则本体在 `EntryConfirmation` 扩展里，
        // 这里只透传 `SweepPlanner` 算好的结果）。谁都不许在这里二次判定。
        draft.confirmRaw = confirmRaw
        return draft
    }

    var occurredDate: DateOnly { DateOnly(key: occurredDay) }

    var amountMoney: Money { Money(cents: amount) }
}

/// 只推进日期、**不生成账目**的扫描结果。
///
/// 两种来源：
/// ① 该期被 `suppressedCycles` 抑制（R-SUB-DEL A 分支）；
/// ② 金额为 0（E-9：只保留提醒）。
///
/// 为什么必须单独有这条记录：若不推进日期，这类订阅会永远停在"已到期"，
/// 每次扫描都重新走一遍补漏循环、UI 也一直显示到期，等于功能坏掉。
struct SubscriptionAdvance: Hashable, Sendable {

    let subscriptionID: UUID
    /// 推进后的下次扣费日。
    let nextBillingDay: Int32
    /// 本次处理到的最后一个周期键（写入 `lastSweptCycleKey`，便于排查）。
    let lastCycleKey: String?
}

/// 不自动续费订阅的到期提示（R-SUB-6：只提醒、不记账）。
struct RenewalNotice: Hashable, Sendable {

    let subscriptionID: UUID
    let name: String
    /// 到期日（= `nextBillingDay`）。
    let dueDay: Int32
    let amount: Int64

    var dueDate: DateOnly { DateOnly(key: dueDay) }

    var amountMoney: Money { Money(cents: amount) }
}

/// 一次扫描的完整计划：纯函数产出、可直接单测、与数据库无关。
struct SweepPlan: Hashable, Sendable {

    /// 要生成的账目（每条 = 一期）。
    var actions: [SweepAction] = []
    /// 只推进日期的订阅（被抑制 / 金额为 0）。
    var advances: [SubscriptionAdvance] = []
    /// 待续费提示（`autoRenew == false` 且已到期）。
    var notices: [RenewalNotice] = []
    /// 命中 24 笔上限的订阅（UI 打标「订阅周期异常，请检查下次扣费日」）。
    var truncatedSubscriptionIDs: [UUID] = []
    /// 因幂等键已存在而跳过的期数（日志/自检用）。
    var skippedDuplicateCount: Int = 0

    /// 计划里没有任何动作（可以直接跳过 `save()`）。
    var isEmpty: Bool {
        actions.isEmpty && advances.isEmpty && notices.isEmpty
    }

    /// 本次计划生成的账目数。
    var generatedCount: Int { actions.count }

    /// 是否命中过 24 笔上限。
    var isTruncated: Bool { !truncatedSubscriptionIDs.isEmpty }
}
