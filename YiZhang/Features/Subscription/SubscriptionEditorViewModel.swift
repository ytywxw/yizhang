//
//  SubscriptionEditorViewModel.swift
//  一账 / Features / Subscription
//
//  职责：订阅编辑页的全部状态与校验（T13）——新建与编辑共用同一个 VM。
//
//  五条刻意的设计：
//  ① **周期是"五档 + 自定义"**：每周 / 每月 / 每季 / 每年 / 自定义（每 N 天、每 N 个月）。
//     底层 `CycleUnit` 有 5 个值，但 `quarter` 与 `year` 在用户脑子里就是"每季/每年"，
//     直接暴露 `cycleValue` 会让 90% 的人面对一个无意义的数字框。
//  ② **手改「下次扣费日」= 校正**：只提示「以此为准」，锚定日由 `SubscriptionService` 重置
//     （R-SUB-8 / E-10）。VM **绝不自算 anchorDay**——两份实现必然漂移。
//  ③ **试用中把「下次扣费日」换成「试用结束日」**：试用期内下次扣费本来就是试用结束日（E-1），
//     同时显示两个日期只会让人以为"试用期还会扣一次"。
//  ④ **保存后立刻扫一次**（`sweep(force: true)`）：用户把首次扣费日改到过去，
//     期望"马上就能看到这笔账"，而不是等下次冷启动（E-10）。
//  ⑤ **补录只返回选项、不自动写账**：补账会污染历史统计，必须用户明确同意（E-5）。
//

import Foundation
import Observation
import SwiftData

// MARK: - 周期档位

/// 周期的五档。
enum CyclePreset: String, CaseIterable, Hashable, Sendable {
    case weekly
    case monthly
    case quarterly
    case yearly
    case custom

    var displayName: String {
        switch self {
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .quarterly: return "每季"
        case .yearly: return "每年"
        case .custom: return "自定义"
        }
    }

    /// 固定档位对应的单位；`custom` 为 nil（由用户另选）。
    var fixedUnit: CycleUnit? {
        switch self {
        case .weekly: return .week
        case .monthly: return .month
        case .quarterly: return .quarter
        case .yearly: return .year
        case .custom: return nil
        }
    }

    /// 由单位的倍数反推档位（编辑模式回填用）。
    static func matching(unit: CycleUnit, value: Int) -> CyclePreset {
        guard value == 1 else { return .custom }
        switch unit {
        case .week: return .weekly
        case .month: return .monthly
        case .quarter: return .quarterly
        case .year: return .yearly
        case .day: return .custom
        }
    }
}

// MARK: - 保存结果

/// 保存成功后的结果。
struct SubscriptionEditorResult: Hashable, Sendable {

    let subscriptionID: UUID
    /// 需要询问补录的选项（试用中 / 无历史期数时为 nil）。
    let backfill: BackfillOption?
    /// 保存瞬间顺手生成的账目数（一般在 0 或 1：改到过去后的当期）。
    let sweepGeneratedCount: Int

    var needsBackfillDecision: Bool { backfill?.isOffered == true }
}

// MARK: - ViewModel

/// 订阅编辑页状态机。
@Observable
@MainActor
final class SubscriptionEditorViewModel {

    /// 模式。
    enum Mode: Hashable {
        case create
        case edit(UUID)

        var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }

        var subscriptionID: UUID? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    // MARK: - 常量

    /// 名称上限（与业务层同一常量）。
    static let nameLimit = SubscriptionService.nameLimit
    /// 备注上限。
    static let noteLimit = 100
    /// 自定义周期倍数的合法范围。
    static let cycleValueRange = 1...366
    /// 提醒天数档位。
    static let reminderChoices = [0, 1, 3, 7]

    // MARK: - 不可变上下文

    let mode: Mode
    let today: DateOnly

    // MARK: - 可编辑状态

    var name: String = ""
    /// 金额文本（分 → 元由 `Money` 负责，这里只存人能看到的那串字符）。
    var amountText: String = "0"
    var preset: CyclePreset = .monthly
    /// 自定义档位的单位（天 / 月）。
    var customUnit: CycleUnit = .day
    var customValue: Int = 30
    var firstBillingDay: DateOnly
    var nextBillingDay: DateOnly
    var hasTrial: Bool = false
    var trialEndDay: DateOnly
    var autoRenew: Bool = true
    var categoryID: UUID?
    var accountID: UUID?
    var note: String = ""
    var reminderDays: Int = 1
    /// 用户是否手改过下次扣费日（用于显示「以此为准」）。
    private(set) var didOverrideNextBilling = false

    // MARK: - 只读数据

    private(set) var categories: [CategoryOption] = []
    private(set) var accounts: [AccountOption] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false
    private(set) var status: SubscriptionStatus = .active

    // MARK: - 依赖

    private var environment: AppEnvironment?

    // MARK: - 初始化

    init(mode: Mode, today: DateOnly = DateOnly(Date())) {
        self.mode = mode
        self.today = today
        firstBillingDay = today
        nextBillingDay = today
        trialEndDay = today.adding(days: 7)
        amountText = ""
    }

    /// 注入依赖：加载分类/账户，编辑模式下回填已有订阅。
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    // MARK: - 加载

    func load() {
        guard let environment else { return }
        do {
            categories = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
                .map(CategoryOption.init)
            accounts = try environment.readContext
                .fetch(QueryDescriptors.accounts(includeArchived: false))
                .map(AccountOption.init)

            applyDefaultsIfNeeded()
            if let id = mode.subscriptionID {
                try loadExisting(id: id, environment: environment)
            }
            errorMessage = nil
        } catch {
            errorMessage = "读取分类和账户失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }
        isLoaded = true
    }

    /// 新建时的默认值：分类默认「订阅服务」，账户默认上次使用的。
    private func applyDefaultsIfNeeded() {
        guard !mode.isEditing else { return }
        if categoryID == nil {
            let presetID = PresetCatalog.subscriptionCategoryID
            categoryID = categories.contains { $0.id == presetID } ? presetID : categories.first?.id
        }
        if accountID == nil {
            let preferred = environment?.settings.defaultAccountID
            if let preferred, accounts.contains(where: { $0.id == preferred }) {
                accountID = preferred
            } else {
                accountID = accounts.first?.id
            }
        }
    }

    /// 编辑模式：把已有订阅的字段回填。
    ///
    /// 直接读 `@Model` 并**只读**取值：这里不持有对象、不回写，改完之后全部经
    /// `SubscriptionService.update` 一次性提交（避免"改了一半、界面上已经是新值"）。
    private func loadExisting(id: UUID, environment: AppEnvironment) throws {
        guard let subscription = try environment.readContext
            .fetch(QueryDescriptors.subscription(id: id))
            .first else {
            errorMessage = "这个订阅已不存在"
            return
        }

        name = subscription.name
        amountText = AmountInput.text(from: Money(cents: max(subscription.amount, 0)))
        preset = CyclePreset.matching(unit: subscription.cycleUnit, value: subscription.cycleValue)
        if preset == .custom {
            customUnit = subscription.cycleUnit
            customValue = max(subscription.cycleValue, 1)
        }
        firstBillingDay = DateOnly(key: subscription.firstBillingDay)
        nextBillingDay = DateOnly(key: subscription.nextBillingDay)
        autoRenew = subscription.autoRenew
        hasTrial = subscription.trialEndDay > 0
        trialEndDay = subscription.trialEndDay > 0
            ? DateOnly(key: subscription.trialEndDay)
            : today.adding(days: 7)
        categoryID = subscription.category?.id
        accountID = subscription.account?.id
        note = subscription.note
        reminderDays = SubscriptionEditorViewModel.reminderChoices.contains(subscription.reminderDays)
            ? subscription.reminderDays
            : 1
        status = subscription.status
        didOverrideNextBilling = false
    }

    // MARK: - 派生

    /// 金额（文本 → 分）。非法/空为 nil。
    var amount: Money? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Money(cents: 0) }
        return AmountInput.money(from: trimmed)
    }

    /// 金额展示（「¥25.00」；0 时显示「免费」）。
    var amountDisplayText: String {
        guard let amount else { return "—" }
        return amount.isZero ? "免费（只提醒，不记账）" : amount.formatted()
    }

    /// 实际会写到库里的周期单位与倍数。
    var resolvedCycle: (unit: CycleUnit, value: Int) {
        if let unit = preset.fixedUnit { return (unit, 1) }
        return (customUnit, min(max(customValue, 1), 366))
    }

    /// 「每 2 个月」这样的描述。
    var cycleText: String {
        let resolved = resolvedCycle
        return resolved.unit.cycleText(value: resolved.value)
    }

    /// 是否处于试用中（试用结束日在今天之后）。
    ///
    /// 试用中时：下次扣费日 = 试用结束日（E-1），且**不提示补录**（试用期还没开始扣钱）。
    var isInTrial: Bool {
        hasTrial && trialEndDay > today
    }

    /// 试用中时展示/生效的下次扣费日。
    var effectiveNextBillingDay: DateOnly {
        isInTrial ? trialEndDay : nextBillingDay
    }

    /// 名称是否合法。
    var isNameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= SubscriptionEditorViewModel.nameLimit
    }

    /// 是否可以保存。
    var canSave: Bool {
        guard isNameValid else { return false }
        guard let amount, amount.cents >= 0 else { return false }
        guard categoryID != nil, accountID != nil else { return false }
        // 首次扣费日不得晚于下次扣费日（试用中比较的是试用结束日）
        return firstBillingDay <= effectiveNextBillingDay
    }

    /// 保存按钮禁用时的一句话解释（`nil` = 可以保存）。
    var saveDisabledReason: String? {
        validationMessage()
    }

    // MARK: - 校验（给 UI 显示原因用）

    /// 逐条检查并返回第一条错误（`nil` = 没问题）。
    func validationMessage() -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "请填写订阅名称" }
        if trimmed.count > SubscriptionEditorViewModel.nameLimit { return "名称最多 30 个字" }
        guard let amount else { return "金额格式不对" }
        if amount.cents < 0 { return "金额不能为负" }
        if !SubscriptionEditorViewModel.cycleValueRange.contains(resolvedCycle.value) {
            return "周期倍数需要在 1 到 366 之间"
        }
        if firstBillingDay > effectiveNextBillingDay {
            return "首次扣费日不能晚于下次扣费日"
        }
        if categoryID == nil { return "请先创建一个支出分类" }
        if accountID == nil { return "请先创建一个账户" }
        return nil
    }

    // MARK: - 交互

    /// 切换周期档位。
    func select(preset newPreset: CyclePreset) {
        preset = newPreset
        errorMessage = nil
    }

    /// 切换自定义周期的单位。
    func select(customUnit newUnit: CycleUnit) {
        customUnit = newUnit == .month ? .month : .day
    }

    /// 改首次扣费日；下次扣费日若还"跟着首次走"就一起改。
    func select(firstBillingDay newDay: DateOnly) {
        let wasFollowing = nextBillingDay == firstBillingDay
        firstBillingDay = newDay
        if wasFollowing, !didOverrideNextBilling {
            nextBillingDay = newDay
        }
        errorMessage = nil
    }

    /// 手改下次扣费日 = 校正（锚定日由服务层重置）。
    func select(nextBillingDay newDay: DateOnly) {
        nextBillingDay = newDay
        didOverrideNextBilling = true
        errorMessage = nil
    }

    /// 开关试用。
    func setTrialEnabled(_ enabled: Bool) {
        hasTrial = enabled
        errorMessage = nil
    }

    /// 选择分类 / 账户。
    func select(categoryID newID: UUID) {
        guard categories.contains(where: { $0.id == newID }) else { return }
        categoryID = newID
        errorMessage = nil
    }

    func select(accountID newID: UUID) {
        guard accounts.contains(where: { $0.id == newID }) else { return }
        accountID = newID
        errorMessage = nil
    }

    /// 清错误。
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 保存

    /// 保存（新建或编辑）。
    ///
    /// - Returns: 成功时的结果（含补录选项）；失败返回 nil 并写入 `errorMessage`。
    @discardableResult
    func save() -> SubscriptionEditorResult? {
        errorMessage = nil
        guard let environment else {
            errorMessage = "数据还没准备好，请稍后再试"
            return nil
        }
        if let message = validationMessage() {
            errorMessage = message
            return nil
        }
        guard let amount else {
            errorMessage = "金额格式不对"
            return nil
        }

        let resolved = resolvedCycle
        let trialKey = isInTrial ? trialEndDay.key : 0

        do {
            let subscriptionID: UUID
            let backfill: BackfillOption?

            switch mode {
            case .create:
                var draft = SubscriptionDraft(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    amount: amount.cents,
                    cycleUnit: resolved.unit,
                    cycleValue: resolved.value,
                    firstBillingDay: firstBillingDay.key
                )
                draft.nextBillingDay = didOverrideNextBilling ? nextBillingDay.key : 0
                draft.autoRenew = autoRenew
                draft.trialEndDay = trialKey
                draft.categoryID = categoryID
                draft.accountID = accountID
                draft.note = String(note.prefix(SubscriptionEditorViewModel.noteLimit))
                draft.reminderDays = reminderDays

                let result = try environment.subscription.create(draft, today: today)
                subscriptionID = result.subscriptionID
                backfill = result.backfill

            case .edit(let id):
                var changes = SubscriptionChanges()
                changes.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.amount = amount.cents
                changes.cycleUnit = resolved.unit
                changes.cycleValue = resolved.value
                changes.firstBillingDay = firstBillingDay.key
                // 只有用户真的改过才传 nextBillingDay：传了就等于"校正"，会重置锚定日（R-SUB-8）
                changes.nextBillingDay = didOverrideNextBilling ? nextBillingDay.key : nil
                changes.autoRenew = autoRenew
                changes.trialEndDay = trialKey
                changes.categoryID = categoryID
                changes.accountID = accountID
                changes.note = String(note.prefix(SubscriptionEditorViewModel.noteLimit))
                changes.reminderDays = reminderDays

                subscriptionID = id
                backfill = try environment.subscription.update(id: id, changing: changes, today: today)
            }

            // E-10：日期改到过去要立刻生效，不能等下次冷启动
            let report = environment.sweep.sweep(today: today, force: true)

            // 试用中不提供补录：试用期还没开始扣钱，补录会把"试用"补成"已付费"
            let offered = isInTrial ? nil : backfill

            return SubscriptionEditorResult(
                subscriptionID: subscriptionID,
                backfill: offered,
                sweepGeneratedCount: report.inserted
            )
        } catch let error as SubscriptionError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)。内容还在，改一下再点保存。"
            return nil
        }
    }

    /// 用户确认补录后执行。
    ///
    /// - Parameters:
    ///   - subscriptionID: 订阅 id。
    ///   - cycles: 期数（0 = 不补）。
    /// - Returns: 实际生成的账目数。
    @discardableResult
    func backfill(subscriptionID: UUID, cycles: Int) -> Int {
        guard let environment else { return 0 }
        do {
            let inserted = try environment.subscription.backfill(
                subscriptionID: subscriptionID,
                cycles: cycles,
                today: today
            )
            // 补录会把 nextBillingDay 推到今天之后，紧接着扫一次让界面与数据同步
            _ = environment.sweep.sweep(today: today, force: true)
            return inserted
        } catch {
            errorMessage = "补录失败：\(error.localizedDescription)"
            return 0
        }
    }

    // MARK: - 状态变更（编辑模式）

    /// 取消订阅（保留记录与历史账目）。
    func cancelSubscription() -> String? {
        guard let environment, let id = mode.subscriptionID else { return nil }
        do {
            try environment.subscription.cancel(id: id)
            status = .cancelled
            return "已取消订阅，历史账目保留"
        } catch let error as SubscriptionError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "取消失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 彻底删除订阅（历史账目保留，但来源显示"已删除"）。
    func deleteSubscription() -> String? {
        guard let environment, let id = mode.subscriptionID else { return nil }
        do {
            try environment.subscription.delete(id: id)
            return "已删除订阅"
        } catch {
            errorMessage = "删除没成功：\(error.localizedDescription)。下拉刷新后重试。"
            return nil
        }
    }
}
