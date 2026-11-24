//
//  EntryViewModel.swift
//  一账 / Features / Entry
//
//  职责：记账输入页的全部状态与业务判断（T07）。
//
//  为什么判断都放这里而不是 View（架构 §5.3）：
//  ① 「保存按钮能不能点」是业务问题（金额 > 0、必须有分类、转账不能转给自己、日期不能是未来），
//     写成 `View` 里的 `if` 就没法单测，也没法复用到编辑模式；
//  ② R-IN-2 的"只填了金额就保存 → 自动选最近用过的分类"是一条**业务规则**，
//     放在 `Button` 的 action 里会被三处复制，然后三处行为不一致；
//  ③ 编辑模式与新建模式共用同一个 VM：差别只有"提交走 create 还是 update"，
//     这个差别也不该漏到 View 里。
//
//  数据来源分两类，刻意分开：
//  - 分类/账户列表：走 `AppEnvironment.readContext`（只读，一次性查询）；
//  - 上次用的账户 / 最近用的分类：走 `AppEnvironment.settings`（唯一实例，写完立即生效）。
//    如果从 readContext 再读一份设置，会读到另一个 `AppSettings` 实例，
//    于是"刚保存的默认账户"在下次打开仍显示旧值——这类 bug 极难复现，直接从源头避免。
//

import Foundation
import Observation
import SwiftData

// MARK: - 选项值类型

/// 分类下拉/宫格用的值类型。
///
/// 刻意不把 `@Model Category` 传进 View：值类型不会因为上下文保存而"悄悄变"，也不持有 context。
struct CategoryOption: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let iconName: String
    let colorHex: String
    let type: EntryType

    init(_ category: Category) {
        id = category.id
        name = category.displayName
        iconName = category.displayIconName
        colorHex = category.colorHex
        type = category.type
    }

    /// 测试/预览用的人造值。
    init(id: UUID, name: String, iconName: String, colorHex: String, type: EntryType) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.type = type
    }
}

/// 账户选择用的值类型。
struct AccountOption: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let symbolName: String

    init(_ account: Account) {
        id = account.id
        name = account.displayName
        symbolName = account.symbolName
    }

    init(id: UUID, name: String, symbolName: String) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
    }
}

// MARK: - 保存结果

/// 一次成功保存的凭据。首页用它做「插入高亮 + Toast + 撤销」。
struct EntrySaveResult: Identifiable, Hashable, Sendable {
    /// 账目 id（新建是插入后的 id，编辑是被改的那条）。
    let id: UUID
    let amount: Money
    let type: EntryType
    let day: DateOnly
    /// Toast 文案，如「已记一笔 ¥28」。
    let message: String
    /// 是否是编辑（编辑不该弹「已记一笔」）。
    let isEdit: Bool

    /// 生成 Toast 文案。整元时省略 `.00`（`¥28` 比 `¥28.00` 更像人话）。
    static func makeMessage(type: EntryType, amount: Money, isEdit: Bool) -> String {
        let text = amount.conciseText
        if isEdit { return "已更新为 \(text)" }
        switch type {
        case .expense: return "已记一笔 \(text)"
        case .income: return "已记一笔收入 \(text)"
        case .transfer: return "已转账 \(text)"
        }
    }
}

// MARK: - ViewModel

/// 记账输入页状态机。
@Observable
@MainActor
final class EntryViewModel {

    // MARK: - 常量

    /// 备注上限（与业务层同一常量，避免两处写成 100 / 99）。
    static let noteLimit = LedgerService.noteLimit
    /// 最近分类保留个数（R-IN-2：最多 6 个）。
    static let recentCategoryLimit = 6

    // MARK: - 不可变上下文

    /// 今天（注入以便测试固定时间）。
    let today: DateOnly

    /// 编辑模式下的账目 id；新建为 nil。
    let editingEntryID: UUID?

    /// 是否为编辑模式。
    var isEditing: Bool { editingEntryID != nil }

    // MARK: - 可编辑状态（View 直接绑）

    /// 账目类型。
    private(set) var type: EntryType = .expense

    /// 金额文本（不含 `¥`，由 `AmountKeypad` 驱动）。
    var amountText: String = ""

    /// 已选分类。
    private(set) var selectedCategoryID: UUID?

    /// 付款账户（转账时为转出账户）。
    private(set) var accountID: UUID?

    /// 转入账户（仅转账）。
    private(set) var toAccountID: UUID?

    /// 发生日期。
    private(set) var day: DateOnly

    /// 备注。
    var note: String = ""

    // MARK: - 只读数据

    /// 支出分类（已排除隐藏项）。
    private(set) var expenseCategories: [CategoryOption] = []
    /// 收入分类（已排除隐藏项）。
    private(set) var incomeCategories: [CategoryOption] = []
    /// 可用账户（已排除归档项）。
    private(set) var accounts: [AccountOption] = []
    /// 最近用过的分类 id，最新的在最前。
    private(set) var recentCategoryIDs: [UUID] = []
    /// 保存/读取失败提示。
    private(set) var errorMessage: String?
    /// 数据是否已加载（首帧防闪）。
    private(set) var isLoaded = false

    // MARK: - 依赖

    /// 环境（`attach` 注入，测试里用内存容器装配）。
    private var environment: AppEnvironment?

    // MARK: - 初始化

    /// - Parameters:
    ///   - today: 今天。
    ///   - editing: 编辑模式的快照；nil 表示新建。
    init(today: DateOnly = DateOnly(Date()), editing snapshot: LedgerEntrySnapshot? = nil) {
        self.today = today
        self.editingEntryID = snapshot?.id
        if let snapshot {
            type = snapshot.type
            amountText = AmountInput.text(from: snapshot.amountMoney)
            selectedCategoryID = snapshot.type.isTransfer ? nil : snapshot.categoryID
            accountID = snapshot.accountID
            toAccountID = snapshot.toAccountID
            day = snapshot.occurredDay > 0 ? snapshot.occurredDate : today
            note = snapshot.note
        } else {
            day = today
        }
    }

    /// 注入依赖并加载分类/账户。
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    // MARK: - 加载

    /// 读取分类与账户，并补齐默认值。
    func load() {
        guard let environment else { return }
        do {
            let expense = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
                .map(CategoryOption.init)
            let income = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .income, includeHidden: false))
                .map(CategoryOption.init)
            let accountList = try environment.readContext
                .fetch(QueryDescriptors.accounts(includeArchived: false))
                .map(AccountOption.init)

            expenseCategories = expense
            incomeCategories = income
            accounts = accountList
            recentCategoryIDs = environment.settings.recentCategoryIDList
            applyDefaults()
            errorMessage = nil
        } catch {
            errorMessage = "读取分类和账户失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }
        isLoaded = true
    }

    /// 默认值：账户取 `defaultAccountID`（失效则取第一个未归档账户）；转账补一个不同的转入账户。
    /// 编辑模式**不覆盖**已有值（用户的数据优先）。
    private func applyDefaults() {
        if accountID == nil {
            let preferred = environment?.settings.defaultAccountID
            if let preferred, accounts.contains(where: { $0.id == preferred }) {
                accountID = preferred
            } else {
                accountID = accounts.first?.id
            }
        }
        if type == .transfer, toAccountID == nil || toAccountID == accountID {
            toAccountID = accounts.first { $0.id != accountID }?.id
        }
    }

    // MARK: - 派生数据

    /// 当前类型可选的分类（转账没有分类）。
    var categories: [CategoryOption] {
        switch type {
        case .expense: return expenseCategories
        case .income: return incomeCategories
        case .transfer: return []
        }
    }

    /// 最近用过的分类（按"最近优先"排序，且必须属于当前类型）。
    ///
    /// 过滤类型是必须的：用户上次记的是「餐饮」（支出），这次切到收入，
    /// 直接把「餐饮」当成最近分类会让保存写出"收入-餐饮"这种脏数据。
    var recentCategories: [CategoryOption] {
        let available = categories
        guard !available.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        var result: [CategoryOption] = []
        var seen = Set<UUID>()
        for id in recentCategoryIDs {
            guard let option = byID[id], !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(option)
            if result.count >= Self.recentCategoryLimit { break }
        }
        return result
    }

    /// 金额（文本 → 分）。空/非法为 nil。
    var amount: Money? {
        AmountInput.money(from: amountText)
    }

    /// 保存时**实际会用**的分类（用户选的就用它，没选就自动补）。
    ///
    /// 顺序：已选 → 最近用过的第一个（同类型）→ 该类型第一个分类。
    /// 最后一级兜底是刻意的：R-CAT-2 禁止无分类账目，如果没有兜底，
    /// 一个全新用户（没有任何"最近分类"）第一次记账会卡在一个禁用的保存按钮上，
    /// 而界面不会告诉他为什么。
    var effectiveCategoryID: UUID? {
        guard !type.isTransfer else { return nil }
        if let selectedCategoryID, categories.contains(where: { $0.id == selectedCategoryID }) {
            return selectedCategoryID
        }
        if let recent = recentCategories.first {
            return recent.id
        }
        return categories.first?.id
    }

    /// 是否可以保存。
    var canSave: Bool {
        guard let amount, amount.cents > 0 else { return false }
        guard accountID != nil else { return false }
        if type.isTransfer {
            guard let to = toAccountID, let from = accountID else { return false }
            return to != from
        }
        return effectiveCategoryID != nil
    }

    /// 保存按钮禁用时的一句话解释（`nil` = 可以保存）。
    var saveDisabledReason: String? {
        if accounts.isEmpty { return "还没有可用账户" }
        guard let amount = amount, amount.cents > 0 else { return "输入金额后即可保存" }
        if type.isTransfer {
            guard let to = toAccountID, let from = accountID else { return "请选择转入账户" }
            if to == from { return "转出和转入不能是同一个账户" }
            return nil
        }
        if effectiveCategoryID == nil { return "请选择一个分类" }
        return nil
    }

    /// 已选分类（用于宫格高亮）。自动选择尚未发生时返回用户的选择。
    var highlightedCategoryID: UUID? { selectedCategoryID }

    /// 转账可选的转入账户（排除转出账户）。
    var transferTargetAccounts: [AccountOption] {
        accounts.filter { $0.id != accountID }
    }

    /// 当前选中账户的展示名。
    var accountName: String {
        accounts.first { $0.id == accountID }?.name ?? "选择账户"
    }

    /// 当前转入账户的展示名。
    var toAccountName: String {
        accounts.first { $0.id == toAccountID }?.name ?? "选择账户"
    }

    /// 金额色调（转账用灰）。
    var amountTone: MoneyText.Tone {
        MoneyText.Tone(type: type)
    }

    // MARK: - 交互

    /// 按下一个键。
    func press(_ key: AmountKey) {
        amountText = AmountInput.apply(key, to: amountText)
        errorMessage = nil
    }

    /// 切换类型。切换时清掉不属于新类型的分类 / 转入账户。
    func select(type newType: EntryType) {
        guard newType != type else { return }
        type = newType
        errorMessage = nil

        if newType.isTransfer {
            // 转账没有分类（PRD 3.2.1），转入账户默认取一个不等于转出账户的
            selectedCategoryID = nil
            if toAccountID == nil || toAccountID == accountID {
                toAccountID = accounts.first { $0.id != accountID }?.id
            }
        } else {
            toAccountID = nil
            if let selectedCategoryID, !categories.contains(where: { $0.id == selectedCategoryID }) {
                self.selectedCategoryID = nil
            }
        }
    }

    /// 选择分类。只接受当前类型的分类（支出/收入互斥）。
    func select(categoryID: UUID) {
        guard categories.contains(where: { $0.id == categoryID }) else { return }
        selectedCategoryID = categoryID
        errorMessage = nil
    }

    /// 选择付款账户（转账时会顺带修正转入账户，避免两者相等）。
    func select(accountID newID: UUID) {
        guard accounts.contains(where: { $0.id == newID }) else { return }
        accountID = newID
        if type.isTransfer, toAccountID == newID {
            toAccountID = accounts.first { $0.id != newID }?.id
        }
        errorMessage = nil
    }

    /// 选择转入账户（转账模式）。
    func select(toAccountID newID: UUID) {
        guard type.isTransfer else { return }
        guard newID != accountID else {
            errorMessage = LedgerError.sameTransferAccount.errorDescription
            return
        }
        toAccountID = newID
        errorMessage = nil
    }

    /// 选择日期。不允许未来。
    func select(day newDay: DateOnly) {
        guard newDay.isValid else {
            errorMessage = LedgerError.invalidDate.errorDescription
            return
        }
        guard newDay <= today else {
            errorMessage = LedgerError.futureDate.errorDescription
            return
        }
        day = newDay
        errorMessage = nil
    }

    /// 清掉错误提示。
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 保存

    /// 保存（新建或编辑）。
    ///
    /// - Returns: 成功时的凭据；失败返回 nil 并把原因写进 `errorMessage`。
    @discardableResult
    func save() -> EntrySaveResult? {
        errorMessage = nil
        guard let environment else {
            errorMessage = "数据还没准备好，请稍后再试"
            return nil
        }
        guard let amount, amount.cents > 0 else {
            errorMessage = LedgerError.amountNotPositive.errorDescription
            return nil
        }
        guard day <= today else {
            errorMessage = LedgerError.futureDate.errorDescription
            return nil
        }
        guard let accountID else {
            errorMessage = LedgerError.missingAccount.errorDescription
            return nil
        }

        let trimmedNote = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.noteLimit))

        // 分类：没选就自动补（R-IN-2），并把结果写回 `selectedCategoryID`，
        // 否则用户会看到"我明明没选分类，账目里却有分类"。
        var resolvedCategoryID: UUID?
        if !type.isTransfer {
            guard let categoryID = effectiveCategoryID else {
                errorMessage = LedgerError.missingCategory.errorDescription
                return nil
            }
            resolvedCategoryID = categoryID
            selectedCategoryID = categoryID
        }

        var resolvedToAccountID: UUID?
        if type.isTransfer {
            guard let to = toAccountID else {
                errorMessage = LedgerError.missingTransferTarget.errorDescription
                return nil
            }
            guard to != accountID else {
                errorMessage = LedgerError.sameTransferAccount.errorDescription
                return nil
            }
            resolvedToAccountID = to
        }

        do {
            let entryID: UUID
            if let editingEntryID {
                let changes = EntryChanges(
                    type: type,
                    amount: amount.cents,
                    occurredDay: day.key,
                    categoryID: resolvedCategoryID,
                    accountID: accountID,
                    toAccountID: resolvedToAccountID,
                    note: trimmedNote
                )
                let snapshot = try environment.ledger.update(id: editingEntryID, changing: changes)
                entryID = snapshot.id
            } else {
                var draft = EntryDraft(
                    typeRaw: type.raw,
                    amount: amount.cents,
                    occurredDay: day.key
                )
                draft.categoryID = resolvedCategoryID
                draft.accountID = accountID
                draft.toAccountID = resolvedToAccountID
                draft.note = trimmedNote
                draft.sourceRaw = EntrySource.manual.raw

                let outcome = try environment.ledger.create(draft)
                switch outcome {
                case .inserted(let id):
                    entryID = id
                case .skippedDuplicate:
                    // 手动记账没有幂等键，理论上不会走到这里；真走到了也不该静默成功
                    errorMessage = "这笔账已经记过了"
                    return nil
                }
            }

            remember(categoryID: resolvedCategoryID, accountID: accountID)

            return EntrySaveResult(
                id: entryID,
                amount: amount,
                type: type,
                day: day,
                message: EntrySaveResult.makeMessage(type: type, amount: amount, isEdit: isEditing),
                isEdit: isEditing
            )
        } catch let error as LedgerError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)。内容还在，改一下再点保存。"
            return nil
        }
    }

    /// 写回「上次用的账户 / 最近用的分类」（R-IN-2 / F-ACC-07）。
    ///
    /// 三个动作同一次提交：内存设置对象 + `saveSettings()` + 本地 `recentCategoryIDs` 同步，
    /// 保证"回到输入页立刻看到新的最近分类"不依赖任何异步刷新。
    private func remember(categoryID: UUID?, accountID: UUID?) {
        guard let environment else { return }
        let settings = environment.settings
        if let accountID {
            settings.defaultAccountID = accountID
        }
        if let categoryID {
            settings.rememberCategory(categoryID, limit: Self.recentCategoryLimit)
        }
        environment.saveSettings()
        recentCategoryIDs = settings.recentCategoryIDList
    }
}

// MARK: - Money 的紧凑展示

extension Money {
    /// 展示文本：整元省略 `.00`（`¥28`），有零头照常两位（`¥28.50`）。
    ///
    /// 放在 `Money` 上而不是各 View 里：`% 100 == 0` 这个判断一旦被复制，
    /// 就会出现"首页写 ¥28、Toast 写 ¥28.00"的不一致。
    var conciseText: String {
        cents % 100 == 0 ? "¥" + wholeYuanDigits : formatted()
    }
}
