//
//  SubscriptionService.swift
//  一账 / Core / Services
//
//  职责：订阅用例层——新建 / 编辑 / 暂停 / 恢复 / 取消 / 重新激活 / 删除 / 已续费 / 补录。
//
//  分层位置与 `LedgerService` 完全一致：
//  `View → ViewModel → SubscriptionService → LedgerWriter + LedgerService → SwiftData`。
//  本类允许 `import SwiftData`（要引用 `Subscription`），**禁止 `import SwiftUI`**，
//  也禁止自己 `context.save()`——提交一律经 `LedgerWriter`，账目一律经 `LedgerService.create`
//  （它负责金额 > 0、分类/账户存在、幂等键补齐这一整套校验）。
//
//  三个容易写错、这里刻意做对的地方：
//  ① **状态机按 PRD 附录 A.2 逐条实现**，非法迁移直接抛错而不是"默默改成 active"——
//     默默修正会让 UI 上的按钮与真实状态长期不一致，用户永远不知道哪次点击生效了。
//  ② **锚定日的重置只发生在两种事件**：新建 / 用户手改 `nextBillingDay`（= 校正）。
//     改周期、结算推进都不动它，否则 1/31 → 2/28 → 3/28 的漂移会重新出现（R-SUB-8）。
//  ③ **补录默认 0 期**：保存只返回 `BackfillOption`，写账由调用方显式再调一次
//     `backfill(subscriptionID:cycles:)`。补账污染历史统计，必须用户明确同意（E-5）。
//
//  本类**不负责**"到期自动生成账目"——那是 `SweepCoordinator`（T11）的事。
//  本类只在两个用户显式动作里写账：`markRenewed`（R-SUB-6 的"已续费"）与 `backfill`（E-5）。
//

import Foundation
import SwiftData

// MARK: - 错误

/// 订阅相关的业务错误。全部带中文 `errorDescription`，UI 可直接展示。
enum SubscriptionError: LocalizedError, Equatable {

    /// 名称不能为空
    case nameEmpty
    /// 名称超过 30 字（PRD 4.1）
    case nameTooLong
    /// 备注超过 100 字
    case noteTooLong
    /// 周期倍数必须在 1…366 之间（PRD 4.1）
    case invalidCycleValue
    /// 日期不是真实自然日
    case invalidDate
    /// 提醒天数只允许 0 / 1 / 3 / 7
    case invalidReminderDays
    /// 订阅不存在（可能已被删除）
    case subscriptionNotFound
    /// 找不到可用的分类（连「订阅服务」预置分类都被删了）
    case missingCategory
    /// 找不到可用的账户
    case missingAccount
    /// 状态机不允许的迁移（PRD 附录 A.2）
    case transitionNotAllowed(from: SubscriptionStatus)
    /// 需要下次扣费日，但它是 0（已取消）
    case missingNextBillingDay
    /// 补录期数非法
    case invalidBackfillCycles

    var errorDescription: String? {
        switch self {
        case .nameEmpty:
            return "订阅名称不能为空"
        case .nameTooLong:
            return "名称最多 30 个字"
        case .noteTooLong:
            return "备注最多 100 字"
        case .invalidCycleValue:
            return "周期需要在 1 到 366 之间"
        case .invalidDate:
            return "日期无效"
        case .invalidReminderDays:
            return "提醒天数只能选当天、1 天、3 天或 7 天"
        case .subscriptionNotFound:
            return "这个订阅已不存在"
        case .missingCategory:
            return "请至少保留一个支出分类"
        case .missingAccount:
            return "请先创建一个账户"
        case .transitionNotAllowed(let from):
            return "当前是「\(from.displayName)」，不能执行这个操作"
        case .missingNextBillingDay:
            return "这个订阅没有下次扣费日"
        case .invalidBackfillCycles:
            return "补录期数需要在 1 到 12 之间"
        }
    }
}

// MARK: - 输入 / 输出值类型

/// 新建订阅的输入。
///
/// 刻意用 `Int32` 日键而不是 `Date`：A2 铁律下自然日就是 `yyyyMMdd` 整数，
/// 从 `Date` 进来到 `DateOnly` 的换算只应发生在 View 层（`DatePicker` 绑定点）。
struct SubscriptionDraft: Hashable, Sendable {

    var name: String = ""
    /// 每期金额（分）。允许 0（E-9：只提醒不记账）。
    var amount: Int64 = 0
    var cycleUnit: CycleUnit = .month
    var cycleValue: Int = 1

    /// 首次扣费日 `yyyyMMdd`；`0` 表示"就用今天"。
    var firstBillingDay: Int32 = 0

    /// 下次扣费日 `yyyyMMdd`；`0` 表示"跟首次扣费日一致"。
    /// 显式填写视为"校正"，会重置锚定日（R-SUB-8）。
    var nextBillingDay: Int32 = 0

    var autoRenew: Bool = true

    /// 免费试用结束日 `yyyyMMdd`；`0` 表示无试用（E-1）。
    var trialEndDay: Int32 = 0

    var categoryID: UUID?
    var accountID: UUID?
    var note: String = ""
    var iconName: String = ""
    var colorHex: String = ""
    /// 提前几天提醒：0 / 1 / 3 / 7。
    var reminderDays: Int = 1

    init(
        name: String = "",
        amount: Int64 = 0,
        cycleUnit: CycleUnit = .month,
        cycleValue: Int = 1,
        firstBillingDay: Int32 = 0,
        nextBillingDay: Int32 = 0,
        autoRenew: Bool = true,
        trialEndDay: Int32 = 0,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        note: String = "",
        iconName: String = "",
        colorHex: String = "",
        reminderDays: Int = 1
    ) {
        self.name = name
        self.amount = amount
        self.cycleUnit = cycleUnit
        self.cycleValue = cycleValue
        self.firstBillingDay = firstBillingDay
        self.nextBillingDay = nextBillingDay
        self.autoRenew = autoRenew
        self.trialEndDay = trialEndDay
        self.categoryID = categoryID
        self.accountID = accountID
        self.note = note
        self.iconName = iconName
        self.colorHex = colorHex
        self.reminderDays = reminderDays
    }
}

/// 编辑订阅时的可变字段集合（`nil` = 不改）。
///
/// 与 `EntryChanges` 同样的思路：**不提供** `status` 字段。
/// 状态只能通过 `pause` / `resume` / `cancel` / `reactivate` 这些语义方法改，
/// 这样"暂停却还在生成账目"这类错状态在类型上就表达不出来。
struct SubscriptionChanges: Hashable, Sendable {

    var name: String?
    var amount: Int64?
    var cycleUnit: CycleUnit?
    var cycleValue: Int?
    var firstBillingDay: Int32?
    /// 显式改 `nextBillingDay` 视为校正，会重置锚定日。
    var nextBillingDay: Int32?
    var autoRenew: Bool?
    /// `0` 表示清除试用。
    var trialEndDay: Int32?
    var categoryID: UUID?
    var accountID: UUID?
    var note: String?
    var iconName: String?
    var colorHex: String?
    var reminderDays: Int?

    init(
        name: String? = nil,
        amount: Int64? = nil,
        cycleUnit: CycleUnit? = nil,
        cycleValue: Int? = nil,
        firstBillingDay: Int32? = nil,
        nextBillingDay: Int32? = nil,
        autoRenew: Bool? = nil,
        trialEndDay: Int32? = nil,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        note: String? = nil,
        iconName: String? = nil,
        colorHex: String? = nil,
        reminderDays: Int? = nil
    ) {
        self.name = name
        self.amount = amount
        self.cycleUnit = cycleUnit
        self.cycleValue = cycleValue
        self.firstBillingDay = firstBillingDay
        self.nextBillingDay = nextBillingDay
        self.autoRenew = autoRenew
        self.trialEndDay = trialEndDay
        self.categoryID = categoryID
        self.accountID = accountID
        self.note = note
        self.iconName = iconName
        self.colorHex = colorHex
        self.reminderDays = reminderDays
    }
}

/// 新建订阅的结果。
struct SubscriptionCreateResult: Hashable, Sendable {
    let subscriptionID: UUID
    /// 写入后的下次扣费日（可能 = 首次扣费日，也可能 = 试用结束日，见 E-1）。
    let nextBillingDay: Int32
    /// 是否询问补录；`nil` 表示没有可补的历史期数。
    let backfill: BackfillOption?

    var needsBackfillDecision: Bool { backfill?.isOffered == true }
}

/// "已续费"的结果（R-SUB-6）。
struct RenewalResult: Hashable, Sendable {
    /// 生成的账目 id；金额为 0 或幂等命中时为 nil。
    let entryID: UUID?
    let nextBillingDay: Int32

    var didGenerate: Bool { entryID != nil }
}

// MARK: - 服务

/// 订阅服务。
@MainActor
final class SubscriptionService {

    /// 名称长度上限（PRD 4.1：≤ 30 字）。
    static let nameLimit = 30
    /// 备注长度上限（PRD 4.1）。
    static let noteLimit = 100
    /// 周期倍数范围（PRD 4.1：1～366）。
    static let cycleValueRange = 1...366
    /// 提醒天数可选项（PRD 4.1：0 / 1 / 3 / 7）。
    static let allowedReminderDays = [0, 1, 3, 7]

    private let writer: LedgerWriter
    private let ledger: LedgerService

    /// 写入提交后的回调（由 `AppEnvironment` 接到 `bumpDataVersion()`）。
    var onDidCommit: (() -> Void)?

    init(writer: LedgerWriter, ledger: LedgerService, onDidCommit: (() -> Void)? = nil) {
        self.writer = writer
        self.ledger = ledger
        self.onDidCommit = onDidCommit
    }

    // MARK: - 查询

    /// 全部订阅（按状态 + 下次扣费日排序，见 `QueryDescriptors.allSubscriptions`）。
    func subscriptions() throws -> [Subscription] {
        try writer.fetch(QueryDescriptors.allSubscriptions())
    }

    /// 某状态的订阅。
    func subscriptions(of status: SubscriptionStatus) throws -> [Subscription] {
        try writer.fetch(QueryDescriptors.subscriptions(of: status))
    }

    func subscription(id: UUID) throws -> Subscription? {
        try writer.subscription(id: id)
    }

    /// 全部订阅快照（总览折合用）。
    func snapshots() throws -> [SubscriptionSnapshot] {
        SubscriptionMapper.snapshots(try subscriptions())
    }

    /// 某状态订阅的快照。
    func snapshots(of status: SubscriptionStatus) throws -> [SubscriptionSnapshot] {
        SubscriptionMapper.snapshots(try subscriptions(of: status))
    }

    /// 单个订阅的快照。
    func snapshot(id: UUID) throws -> SubscriptionSnapshot? {
        guard let subscription = try writer.subscription(id: id) else { return nil }
        return SubscriptionMapper.snapshot(of: subscription)
    }

    // MARK: - 新建

    /// 新建订阅。
    ///
    /// 关键分支：
    /// - 试用未结束（E-1）：`firstBillingDay` / `nextBillingDay` 都对齐到试用结束日，
    ///   试用期内**不生成任何账目**，也不提供补录；
    /// - 首次扣费日在过去（E-5）：不自动补账，只返回 `BackfillOption` 让调用方询问用户；
    /// - 金额为 0（E-9）：允许保存，但不提供补录（没有账目可补）。
    ///
    /// - Parameters:
    ///   - draft: 新建输入。
    ///   - today: 今天（测试注入固定日）。
    /// - Returns: 新订阅 id + 下次扣费日 + 可选补录选项。
    @discardableResult
    func create(_ draft: SubscriptionDraft, today: DateOnly = DateOnly(Date())) throws -> SubscriptionCreateResult {
        let name = try validatedName(draft.name)
        let note = try validatedNote(draft.note)
        let cycleValue = try validatedCycleValue(draft.cycleValue)
        let reminderDays = try validatedReminderDays(draft.reminderDays)
        let amount = max(draft.amount, 0)

        let firstDate: DateOnly
        if draft.firstBillingDay > 0 {
            firstDate = try checkedDay(draft.firstBillingDay)
        } else {
            firstDate = today
        }
        guard firstDate.key > 0 else { throw SubscriptionError.invalidDate }

        var trialDay: DateOnly?
        if draft.trialEndDay > 0 {
            trialDay = try checkedDay(draft.trialEndDay)
        }
        let isTrialActive = trialDay.map { $0 > today } ?? false

        // 起始扣费日：试用中必须对齐到试用结束日（E-1），否则由用户显式校正值决定
        let startDate: DateOnly
        if isTrialActive, let trialDay {
            startDate = trialDay
        } else if draft.nextBillingDay > 0 {
            startDate = try checkedDay(draft.nextBillingDay)
        } else {
            startDate = firstDate
        }

        let now = Date()
        let subscription = Subscription()
        subscription.name = name
        subscription.amount = amount
        subscription.cycleUnit = draft.cycleUnit
        subscription.cycleValue = cycleValue
        // 锚定日 = 起始扣费日的日号（新建时唯一的两个重置时点之一，R-SUB-8）
        subscription.billingAnchorDay = min(max(startDate.day, 1), 31)
        subscription.firstBillingDay = (isTrialActive ? startDate : firstDate).key
        subscription.nextBillingDay = startDate.key
        subscription.autoRenew = draft.autoRenew
        subscription.trialEndDay = trialDay?.key ?? 0
        subscription.status = .active
        subscription.note = note
        subscription.iconName = draft.iconName
        subscription.colorHex = draft.colorHex
        subscription.reminderDays = reminderDays
        subscription.suppressedCycles = []
        subscription.createdAt = now
        subscription.updatedAt = now
        subscription.category = try resolvedCategory(draft.categoryID)
        subscription.account = try resolvedAccount(draft.accountID)

        try writer.insert(subscription)
        onDidCommit?()

        let option = backfillOption(for: subscription, today: today)
        return SubscriptionCreateResult(
            subscriptionID: subscription.id,
            nextBillingDay: subscription.nextBillingDay,
            backfill: option
        )
    }

    // MARK: - 编辑

    /// 编辑订阅（E-2 涨价只影响未来；E-10 手改日期视为校正）。
    ///
    /// - Parameters:
    ///   - id: 订阅 id。
    ///   - changes: 要改的字段（`nil` = 不改）。
    ///   - today: 今天（用于判断是否需要提示补录）。
    /// - Returns: 改完后是否出现"可补录的历史期数"；没有则 nil。
    @discardableResult
    func update(
        id: UUID,
        changing changes: SubscriptionChanges,
        today: DateOnly = DateOnly(Date())
    ) throws -> BackfillOption? {
        guard let subscription = try writer.subscription(id: id) else {
            throw SubscriptionError.subscriptionNotFound
        }

        let name = try changes.name.map { try validatedName($0) } ?? subscription.name
        let note = try changes.note.map { try validatedNote($0) } ?? subscription.note
        let amount = changes.amount.map { max($0, 0) } ?? subscription.amount
        let cycleUnit = changes.cycleUnit ?? subscription.cycleUnit
        let cycleValue = try changes.cycleValue.map { try validatedCycleValue($0) } ?? subscription.cycleValue
        let reminderDays = try changes.reminderDays.map { try validatedReminderDays($0) }
            ?? subscription.reminderDays
        let autoRenew = changes.autoRenew ?? subscription.autoRenew
        let firstDay = try changes.firstBillingDay.map { try checkedDay($0) }
            ?? DateOnly(key: subscription.firstBillingDay)
        guard firstDay.key > 0 else { throw SubscriptionError.invalidDate }

        // 试用：`0` 表示清除；改成未来日期时把下次扣费日对齐过去（E-1）
        var trialDayKey = subscription.trialEndDay
        if let requested = changes.trialEndDay {
            if requested > 0 {
                trialDayKey = try checkedDay(requested).key
            } else {
                trialDayKey = 0
            }
        }

        // 下次扣费日：显式修改 = 校正 → 重置锚定日（R-SUB-8）
        var nextDayKey = subscription.nextBillingDay
        var anchorDay = subscription.billingAnchorDay
        if let requested = changes.nextBillingDay, requested > 0 {
            let day = try checkedDay(requested)
            nextDayKey = day.key
            anchorDay = min(max(day.day, 1), 31)
        } else if subscription.status != .cancelled,
                  trialDayKey > 0,
                  trialDayKey > today.key,
                  nextDayKey != trialDayKey {
            let trialDay = DateOnly(key: trialDayKey)
            nextDayKey = trialDay.key
            anchorDay = min(max(trialDay.day, 1), 31)
        }

        let categoryID = changes.categoryID ?? subscription.category?.id
        let accountID = changes.accountID ?? subscription.account?.id
        let category = try resolvedCategory(categoryID)
        let account = try resolvedAccount(accountID)
        let now = Date()

        try writer.update(subscription) { model in
            model.name = name
            model.amount = amount
            model.cycleUnit = cycleUnit
            model.cycleValue = cycleValue
            model.billingAnchorDay = anchorDay
            model.firstBillingDay = firstDay.key
            model.nextBillingDay = nextDayKey
            model.autoRenew = autoRenew
            model.trialEndDay = trialDayKey
            model.note = note
            model.reminderDays = reminderDays
            model.category = category
            model.account = account
            if let iconName = changes.iconName { model.iconName = iconName }
            if let colorHex = changes.colorHex { model.colorHex = colorHex }
            model.updatedAt = now
        }
        onDidCommit?()

        return backfillOption(for: subscription, today: today)
    }

    // MARK: - 状态机（PRD 附录 A.2）

    /// active → paused：停止生成，`nextBillingDay` **保留不动**（A.2 / E-4）。
    func pause(id: UUID) throws {
        let subscription = try requireSubscription(id: id)
        guard subscription.status == .active else {
            throw SubscriptionError.transitionNotAllowed(from: subscription.status)
        }
        try writer.update(subscription) { model in
            model.status = .paused
            model.updatedAt = Date()
        }
        onDidCommit?()
    }

    /// paused → active：若 `nextBillingDay <= 今天`，顺延到"今天之后第一个周期日"，
    /// **不为暂停期补账**（A.2 / E-4）。
    func resume(id: UUID, today: DateOnly = DateOnly(Date())) throws {
        let subscription = try requireSubscription(id: id)
        guard subscription.status == .paused else {
            throw SubscriptionError.transitionNotAllowed(from: subscription.status)
        }

        let origin = subscription.nextBillingDay > 0
            ? DateOnly(key: subscription.nextBillingDay)
            : today
        let advanced = CycleAdvancer.advanceToFuture(
            from: origin,
            today: today,
            unit: subscription.cycleUnit,
            value: subscription.cycleValue,
            anchorDay: subscription.billingAnchorDay
        )

        try writer.update(subscription) { model in
            model.status = .active
            model.nextBillingDay = advanced.key
            model.updatedAt = Date()
        }
        onDidCommit?()
    }

    /// active / paused → cancelled：停止生成，`nextBillingDay` 置空，**历史账目全部保留**（E-3）。
    func cancel(id: UUID) throws {
        let subscription = try requireSubscription(id: id)
        guard subscription.status == .active || subscription.status == .paused else {
            throw SubscriptionError.transitionNotAllowed(from: subscription.status)
        }
        try writer.update(subscription) { model in
            model.status = .cancelled
            model.nextBillingDay = 0
            model.updatedAt = Date()
        }
        onDidCommit?()
    }

    /// cancelled → active：必须重设 `nextBillingDay`，默认"今天 + 1 个周期"，
    /// 同时把锚定日重置为新日期的日号（A.2：这是一次显式校正）。
    func reactivate(
        id: UUID,
        nextBillingDay: Int32? = nil,
        today: DateOnly = DateOnly(Date())
    ) throws {
        let subscription = try requireSubscription(id: id)
        guard subscription.status == .cancelled else {
            throw SubscriptionError.transitionNotAllowed(from: subscription.status)
        }

        let startDate: DateOnly
        if let nextBillingDay, nextBillingDay > 0 {
            startDate = try checkedDay(nextBillingDay)
        } else {
            startDate = CycleAdvancer.advance(
                from: today,
                unit: subscription.cycleUnit,
                value: subscription.cycleValue,
                anchorDay: subscription.billingAnchorDay
            )
        }
        guard startDate.key > 0 else { throw SubscriptionError.invalidDate }

        try writer.update(subscription) { model in
            model.status = .active
            model.nextBillingDay = startDate.key
            model.billingAnchorDay = min(max(startDate.day, 1), 31)
            model.updatedAt = Date()
        }
        onDidCommit?()
    }

    /// 删除订阅（E-11）：移除记录，历史账目的 `sourceRefID` 悬空保留，UI 显示「订阅已删除」。
    ///
    /// 与「取消」的区别：取消保留订阅本身（可以恢复、可以看总览），删除后什么都不剩。
    func delete(id: UUID) throws {
        guard let subscription = try writer.subscription(id: id) else { return }
        try writer.delete(subscription)
        onDidCommit?()
    }

    // MARK: - 抑制周期（R-SUB-DEL A 分支）

    /// 把某个周期键写入 `suppressedCycles`：**该周期不再自动生成账目**。
    ///
    /// 使用场景（T09 / R-SUB-DEL 分支 A）：用户删掉了一笔订阅自动生成的账目，
    /// 但下次扣费日**不回退**。于是这个周期已经"用掉"了，可它既没有账目、
    /// 也不该在下次扫描时被补回来——把它记进抑制表就是这个意思。
    ///
    /// 与"幂等键已存在"的关系：软删的账目仍然占用幂等键（R-SUB-7），
    /// 所以扫描本来也会跳过这一期。抑制表是**第二道保险**：万一将来某条路径
    /// 真的把那条软删记录硬删了，抑制表仍然能挡住"账目复活"（风险 R8 的一半）。
    ///
    /// - Parameters:
    ///   - cycleKey: 周期键（month/quarter/year → `yyyy-MM`；day/week → `d-yyyyMMdd`）。
    ///   - subscriptionID: 订阅 id。
    /// - Returns: 是否新写入（已经抑制过返回 `false`，不是错误）。
    @discardableResult
    func suppress(cycleKey: String, of subscriptionID: UUID) throws -> Bool {
        guard !cycleKey.isEmpty else { return false }
        guard let subscription = try writer.subscription(id: subscriptionID) else {
            throw SubscriptionError.subscriptionNotFound
        }
        guard !subscription.suppressedCycleSet.contains(cycleKey) else { return false }

        try writer.update(subscription) { model in
            var cycles = model.suppressedCycleSet
            cycles.insert(cycleKey)
            model.suppressedCycleSet = cycles
            model.updatedAt = Date()
        }
        onDidCommit?()
        return true
    }

    /// 撤销抑制（配合「撤销删除」）。
    ///
    /// 只有"删了订阅账目又立刻撤销"才会用到。不提供的话，撤销后该周期仍被抑制，
    /// 一旦那条账目将来被硬删（T14 的 B 分支），这一期就真的再也回不来了——
    /// 撤销的语义应该是"回到删除前"，抑制表也必须一起回退。
    @discardableResult
    func unsuppress(cycleKey: String, of subscriptionID: UUID) throws -> Bool {
        guard !cycleKey.isEmpty else { return false }
        guard let subscription = try writer.subscription(id: subscriptionID) else { return false }
        guard subscription.suppressedCycleSet.contains(cycleKey) else { return false }

        try writer.update(subscription) { model in
            var cycles = model.suppressedCycleSet
            cycles.remove(cycleKey)
            model.suppressedCycleSet = cycles
            model.updatedAt = Date()
        }
        onDidCommit?()
        return true
    }


    // MARK: - 回退周期（R-SUB-DEL B 分支）

    /// 把某个周期"退回未生成"：`nextBillingDay` 退回该期应扣日、锚定日跟着它走、
    /// 清 `lastSweptCycleKey`、并把该键从 `suppressedCycles` 移除。
    ///
    /// 与 A 分支（`suppress`）的差别是**语义相反**：
    /// A = "这一期我不要了，别再补"；B = "这一期当作没扣过，下次启动重新生成"。
    /// 所以 B 分支的账目必须**硬删除**——软删记录仍然占着幂等键（R-SUB-7），
    /// 扫描永远会跳过它，"重新生成"就成了空话（风险 R8）。
    ///
    /// - Parameters:
    ///   - cycleKey: 周期键（`yyyy-MM` 或 `d-yyyyMMdd`）。
    ///   - subscriptionID: 订阅 id。
    /// - Returns: 回退后的下次扣费日；周期键无法解析时返回 nil（不抛错，订阅保持原样）。
    @discardableResult
    func revertCycle(cycleKey: String, of subscriptionID: UUID) throws -> DateOnly? {
        guard let subscription = try writer.subscription(id: subscriptionID) else {
            throw SubscriptionError.subscriptionNotFound
        }
        guard let dueDay = SubscriptionService.dueDay(
            fromCycleKey: cycleKey,
            anchorDay: subscription.billingAnchorDay
        ) else { return nil }

        try writer.update(subscription) { model in
            model.nextBillingDay = dueDay.key
            // 锚定日**不动**，这是 R-SUB-8 的硬要求（偏差 D20）。
            //
            // 直觉上"回退到 2/28 就把锚定日改成 28"是错的：31 号订阅的周期是
            // 1/31 → 2/28 → 3/31，2/28 只是 31 号被当月天数夹过之后的**投影**。
            // 一旦把锚定日写成 28，下一期会算成 3/28 并从此永久漂到 28 号——
            // 正是 `CycleAdvancer` 传固定 `anchorDay` 想避免的那种漂移。
            // 不夹的月份（锚定 15 日回退到 15 日）两者等价，所以"不动"在所有情况下都成立。
            model.lastSweptCycleKey = nil
            var cycles = model.suppressedCycleSet
            cycles.remove(cycleKey)
            model.suppressedCycleSet = cycles
            model.updatedAt = Date()
        }
        onDidCommit?()
        return dueDay
    }

    /// 由周期键反推"该期应扣日"。
    ///
    /// 两种键格式（架构 §3.7 D2）：
    /// - `d-yyyyMMdd`（day / week）→ 键里就带日期，直接解析；
    /// - `yyyy-MM`（month / quarter / year）→ 日期是"该月的锚定日"，按当月天数夹一下
    ///   （锚定日 31 遇到 2 月要落到 28/29，与 `CycleAdvancer` 的期末对齐一致）。
    static func dueDay(fromCycleKey cycleKey: String, anchorDay: Int) -> DateOnly? {
        if cycleKey.hasPrefix("d-") {
            guard let key = Int32(cycleKey.dropFirst(2)) else { return nil }
            let day = DateOnly(key: key)
            return day.isValid ? day : nil
        }
        let parts = cycleKey.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        let day = min(max(anchorDay, 1), DateOnly.daysInMonth(year: year, month: month))
        return DateOnly(year: year, month: month, day: day)
    }

    // MARK: - 已续费（R-SUB-6）

    /// 不自动续费的订阅点「已续费」：生成当期账目 + 推进一个周期。

    ///
    /// - 只对 `autoRenew == false` 且 `active` 的订阅有意义；其它情况返回 nil（不是错误，
    ///   因为 UI 的按钮状态可能与数据有一帧延迟）。
    /// - 到期日必须 `<= 今天`，否则返回 nil。
    /// - 账目 + 日期推进在同一个 `save()` 里提交。
    ///
    /// - Parameters:
    ///   - id: 订阅 id。
    ///   - today: 今天。
    /// - Returns: 生成结果；不适用时 nil。
    @discardableResult
    func markRenewed(id: UUID, today: DateOnly = DateOnly(Date())) throws -> RenewalResult? {
        guard let subscription = try writer.subscription(id: id) else {
            throw SubscriptionError.subscriptionNotFound
        }
        guard subscription.status == .active, !subscription.autoRenew else { return nil }
        guard subscription.nextBillingDay > 0 else { throw SubscriptionError.missingNextBillingDay }

        let dueDay = DateOnly(key: subscription.nextBillingDay)
        guard dueDay <= today else { return nil }

        let cycleKey = SubscriptionMapper.snapshot(of: subscription).cycleKey(for: dueDay)
        let nextDay = CycleAdvancer.advance(
            from: dueDay,
            unit: subscription.cycleUnit,
            value: subscription.cycleValue,
            anchorDay: subscription.billingAnchorDay
        )

        var entryID: UUID?
        if subscription.amount > 0 {
            let outcome = try ledger.create(entryDraft(for: subscription, day: dueDay), save: false)
            entryID = outcome.entryID
        }

        try writer.update(subscription, save: false) { model in
            model.nextBillingDay = nextDay.key
            model.lastSweptCycleKey = cycleKey
            model.updatedAt = Date()
        }
        try writer.save()
        onDidCommit?()
        return RenewalResult(entryID: entryID, nextBillingDay: nextDay.key)
    }

    // MARK: - 补录（E-5）

    /// 为已过去的历史周期补生成账目。
    ///
    /// 顺序说明：只补**最近** N 期（`pastCycles.suffix`）。
    /// 理由：`availableCycles` 超过 12 时用户看到的是"最近 12 期"，若从最早一期开始补，
    /// 补完之后最近的几期反而仍缺失，用户会以为补录没生效。
    ///
    /// - Parameters:
    ///   - subscriptionID: 订阅 id。
    ///   - cycles: 补录期数（0 表示用户选择不补，直接返回 0；>12 按 12 处理）。
    ///   - today: 今天。
    /// - Returns: 实际新生成的账目数（幂等命中不计）。
    @discardableResult
    func backfill(
        subscriptionID: UUID,
        cycles: Int,
        today: DateOnly = DateOnly(Date())
    ) throws -> Int {
        guard let subscription = try writer.subscription(id: subscriptionID) else {
            throw SubscriptionError.subscriptionNotFound
        }
        let requested = min(max(cycles, 0), BackfillOption.maximumCycles)
        // 0 期是合法选择（默认不补）；金额为 0 时没有账目可补（E-9）
        guard requested > 0, subscription.amount > 0 else { return 0 }
        guard subscription.nextBillingDay > 0 else { return 0 }

        let candidates = BackfillPlanner.pastCycles(
            nextBillingDay: DateOnly(key: subscription.nextBillingDay),
            anchorDay: subscription.billingAnchorDay,
            unit: subscription.cycleUnit,
            value: subscription.cycleValue,
            today: today
        )
        guard !candidates.isEmpty else { return 0 }

        let chosen = Array(candidates.suffix(requested))
        var inserted = 0
        for day in chosen {
            let outcome = try ledger.create(entryDraft(for: subscription, day: day), save: false)
            if outcome.wasInserted { inserted += 1 }
        }

        // 补录后把下次扣费日推到今天之后：否则紧接着的结算扫描会把同一批周期再走一遍，
        // 虽然幂等键能挡住，但 `skipped` 计数会虚高、排查变难。
        let advanced = CycleAdvancer.advanceToFuture(
            from: DateOnly(key: subscription.nextBillingDay),
            today: today,
            unit: subscription.cycleUnit,
            value: subscription.cycleValue,
            anchorDay: subscription.billingAnchorDay
        )
        if advanced.key != subscription.nextBillingDay {
            try writer.update(subscription, save: false) { model in
                model.nextBillingDay = advanced.key
                model.updatedAt = Date()
            }
        }

        try writer.save()
        if inserted > 0 { onDidCommit?() }
        return inserted
    }

    // MARK: - 内部：草稿组装

    /// 组装一笔订阅账目草稿（应扣日 = 该期日期，绝不用今天，R-SUB-4①）。
    private func entryDraft(for subscription: Subscription, day: DateOnly) throws -> EntryDraft {
        let category = try resolveCategoryObject(preferredID: subscription.category?.id)
        let account = try resolveAccountObject(preferredID: subscription.account?.id)

        let snapshot = SubscriptionMapper.snapshot(of: subscription)
        var draft = EntryDraft(
            typeRaw: EntryType.expense.raw,
            amount: max(subscription.amount, 0),
            occurredDay: day.key
        )
        draft.categoryID = category.id
        draft.accountID = account.id
        draft.note = "订阅：\(subscription.displayName)"
        draft.sourceRaw = EntrySource.subscription.raw
        draft.sourceRefID = subscription.id
        draft.sourceCycleKey = snapshot.cycleKey(for: day)
        // 幂等键由 LedgerService 按 (sourceRefID, sourceCycleKey) 补齐，不在这里再拼一次
        return draft
    }

    /// 可补录的历史期数（没有则 nil）。
    private func backfillOption(for subscription: Subscription, today: DateOnly) -> BackfillOption? {
        guard subscription.nextBillingDay > 0, subscription.amount > 0 else { return nil }
        let past = BackfillPlanner.pastCycles(
            nextBillingDay: DateOnly(key: subscription.nextBillingDay),
            anchorDay: subscription.billingAnchorDay,
            unit: subscription.cycleUnit,
            value: subscription.cycleValue,
            today: today
        )
        guard !past.isEmpty else { return nil }
        return BackfillOption(subscriptionID: subscription.id, pastCycles: past)
    }

    // MARK: - 内部：分类 / 账户兜底

    /// 分类兜底顺序：传入 id → 「订阅服务」预置分类 → 第一个未隐藏的支出分类。
    private func resolvedCategory(_ preferredID: UUID?) throws -> Category {
        try resolveCategoryObject(preferredID: preferredID)
    }

    private func resolveCategoryObject(preferredID: UUID?) throws -> Category {
        if let preferredID, let category = try writer.category(id: preferredID) {
            return category
        }
        if let preset = try writer.category(id: PresetCatalog.subscriptionCategoryID) {
            return preset
        }
        // 不按 isHidden 排序（Bool 不是 Comparable），隐藏项已在谓词里排除
        let expenseCategories = try writer.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: false)
        )
        if let first = expenseCategories.first { return first }
        throw SubscriptionError.missingCategory
    }

    /// 账户兜底顺序：传入 id → 第一个未归档账户（按 sortOrder）。
    private func resolvedAccount(_ preferredID: UUID?) throws -> Account {
        try resolveAccountObject(preferredID: preferredID)
    }

    private func resolveAccountObject(preferredID: UUID?) throws -> Account {
        if let preferredID, let account = try writer.account(id: preferredID) {
            return account
        }
        let accounts = try writer.fetch(QueryDescriptors.accounts(includeArchived: false))
        if let first = accounts.first { return first }
        throw SubscriptionError.missingAccount
    }

    private func requireSubscription(id: UUID) throws -> Subscription {
        guard let subscription = try writer.subscription(id: id) else {
            throw SubscriptionError.subscriptionNotFound
        }
        return subscription
    }

    // MARK: - 内部：校验

    private func validatedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SubscriptionError.nameEmpty }
        guard trimmed.count <= SubscriptionService.nameLimit else { throw SubscriptionError.nameTooLong }
        return trimmed
    }

    private func validatedNote(_ raw: String) throws -> String {
        guard raw.count <= SubscriptionService.noteLimit else { throw SubscriptionError.noteTooLong }
        return raw
    }

    private func validatedCycleValue(_ raw: Int) throws -> Int {
        guard SubscriptionService.cycleValueRange.contains(raw) else {
            throw SubscriptionError.invalidCycleValue
        }
        return raw
    }

    private func validatedReminderDays(_ raw: Int) throws -> Int {
        guard SubscriptionService.allowedReminderDays.contains(raw) else {
            throw SubscriptionError.invalidReminderDays
        }
        return raw
    }

    private func checkedDay(_ key: Int32) throws -> DateOnly {
        let day = DateOnly(key: key)
        guard day.isValid else { throw SubscriptionError.invalidDate }
        return day
    }
}
