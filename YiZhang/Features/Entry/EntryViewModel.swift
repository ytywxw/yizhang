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

/// 常用模板 chip 用的值类型（F-ACC-14）。
///
/// 与 `CategoryOption` / `AccountOption` 同风格：`@Model EntryTemplate` 不泄漏到 View 层。
/// 只带**填表要用到的字段**（不含 `sortOrder` / `createdAt`）：
/// 顺序由 `TemplateService.all()` 保证，ViewModel 不重新排序（服务已按
/// `sortOrder → createdAt → id` 排好，重排一次就多一份会分叉的口径）。
struct TemplateOption: Identifiable, Hashable, Sendable {
    let id: UUID
    /// chip 上显示的名字（`EntryTemplate.displayName`，空串已兜底成「未命名模板」）。
    let name: String
    let type: EntryType
    /// 预设金额（分）。`hasAmount == false` 时无意义。
    let amount: Int64
    /// 是否预设金额（PRD 5.3-2）。
    let hasAmount: Bool
    let note: String
    let categoryID: UUID?
    let accountID: UUID?

    init(_ template: EntryTemplate) {
        id = template.id
        name = template.displayName
        type = template.type
        amount = template.amount
        hasAmount = template.hasAmount
        note = template.note
        categoryID = template.category?.id
        accountID = template.account?.id
    }

    /// 测试/预览用的人造值。
    init(
        id: UUID,
        name: String,
        type: EntryType = .expense,
        amount: Int64 = 0,
        hasAmount: Bool = false,
        note: String = "",
        categoryID: UUID? = nil,
        accountID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.amount = amount
        self.hasAmount = hasAmount
        self.note = note
        self.categoryID = categoryID
        self.accountID = accountID
    }

    /// chip 上的金额后缀（`hasAmount == false` 时不显示，见 PRD 5.1 的 `☕ 咖啡` 例子）。
    var amountSuffix: String? {
        guard hasAmount else { return nil }
        return Money(cents: max(amount, 0)).conciseText
    }
}

/// 模板填过的字段（用于 0.3s 高亮脉冲，PRD 未要求，但"点了没反应"是最常见的反馈源）。
enum TemplateField: String, Hashable, Sendable, CaseIterable {
    case amount
    case category
    case account
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
    /// 常用模板（顺序即 `TemplateService.all()` 的顺序，不重排）。
    private(set) var templates: [TemplateOption] = []
    /// 是否还能再建模板（满 20 时 chips 行的「＋」置灰）。
    private(set) var canCreateTemplate = true
    /// 已归档账户的 id（用来把「账户已归档」和「账户已删除」说清楚，PRD 5.3-4）。
    private(set) var archivedAccountIDs: Set<UUID> = []
    /// 点模板后 chips 行下方的小字（逐字段降级的唯一反馈方式，不弹错误）。
    private(set) var templateWarning: String?
    /// 刚被模板填过的字段（0.3s 后自动清空，View 用它做高亮脉冲）。
    private(set) var templateFlash: Set<TemplateField> = []
    /// 用户是否手动改过日期（模板不覆盖这种选择）。
    private(set) var hasCustomDay = false
    /// 高亮脉冲的计时器（连续点两个模板时先取消上一次）。
    private var flashTask: Task<Void, Never>?
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
            // 编辑模式：日期是这条账目自己的数据，模板不该把它弹回今天
            hasCustomDay = true
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
            // 归档账户要单独取一份 id：`accounts` 已排除归档项，只剩 id 就没法把
            // 「账户已归档」（保留关系，PRD 5.3-4）和「账户已删除」（关系被 nullify）分开
            archivedAccountIDs = Set(
                try environment.readContext
                    .fetch(QueryDescriptors.accounts(includeArchived: true))
                    .filter(\.isArchived)
                    .map(\.id)
            )
            reloadTemplates()
            applyDefaults()
            errorMessage = nil
        } catch {
            errorMessage = "读取分类和账户失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }
        isLoaded = true
    }

    /// 重新读取模板（新建/编辑/删除/排序后回到记账页时用）。
    ///
    /// 读取失败**不写 `errorMessage`**：模板只是输入辅助，读不到就当没有模板，
    /// 不该让「记一笔」这一页因为 chips 而弹红字——那会把一次正常的记账挡住。
    func reloadTemplates() {
        guard let environment else { return }
        templates = (try? environment.template.all().map(TemplateOption.init)) ?? []
        canCreateTemplate = (try? environment.template.canCreate()) ?? true
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
        // 手动改回今天 ≈ 没有自定义日期，模板可以再把它设回今天（值相同，无副作用）
        hasCustomDay = newDay != today
        errorMessage = nil
    }

    // MARK: - 模板（F-ACC-14）

    /// 分类 id → 选项（chips 行拿它取图标与颜色；找不到返回 nil）。
    func categoryOption(for id: UUID?) -> CategoryOption? {
        guard let id else { return nil }
        if let match = expenseCategories.first(where: { $0.id == id }) { return match }
        return incomeCategories.first { $0.id == id }
    }

    /// 把一个模板填进表单。
    ///
    /// 六条规则，逐条都是刻意的（PRD §5.1 / §5.3）：
    /// ① **类型跟着模板走**：模板固定的是「餐饮 25 元微信」这一整套，只填金额不换类型
    ///    会写出「收入-餐饮」这种脏数据；
    /// ② **`hasAmount == true` 才覆盖金额**；`false` 时**绝不碰用户已输入的数字**——
    ///    「咖啡 / 通勤」这类模板的主力用法就是"只固定分类和账户，金额每天不同"，
    ///    写成"清空"会把功能废掉（PRD 5.3-2）；
    /// ③ 分类 / 账户 / 备注能填就填；
    /// ④ **日期恒为今天**（模板不存日期），但**不覆盖用户手动改过的日期**：
    ///    用户刚选了「昨天」，点一下模板就把日期弹回今天，等于偷偷改了数据；
    /// ⑤ 分类已删 / 账户已归档 → **逐字段降级**：该字段保持当前默认、**不弹错误**、
    ///    不中断填表，只在 chips 行下方留一行小字（错误弹窗会让人以为整个模板坏了）；
    /// ⑥ **填模板 ≠ 保存**：不调 `save()`，也不写「上次账户 / 最近分类」（F-ACC-07）。
    ///    模板一旦被点，模板值**优先于** `applyDefaults()`——后者只在 `load()` 里跑，
    ///    这里不需要反向压制它。
    func applyTemplate(_ template: TemplateOption) {
        errorMessage = nil
        templateWarning = nil
        var filled: Set<TemplateField> = []
        var warnings: [String] = []

        // ① 类型（走既有 `select(type:)`，顺带清掉与新类型不兼容的分类 / 转入账户）
        if template.type != type {
            select(type: template.type)
        }

        // ② 金额
        if template.hasAmount {
            amountText = AmountInput.text(from: Money(cents: max(template.amount, 0)))
            filled.insert(.amount)
        }

        // ③ 分类：转账没有分类，先挡一道（模板本身不支持转账，这里只是防御）
        if !type.isTransfer, let categoryID = template.categoryID {
            if categories.contains(where: { $0.id == categoryID }) {
                selectedCategoryID = categoryID
                filled.insert(.category)
            } else {
                // 分类被删（V1.0 的强制迁移保证实际只剩"类型不匹配"这一种可能）
                warnings.append("模板里的分类已不可用")
            }
        }

        // ④ 账户：归档与删除给不同文案，用户才知道该归档恢复还是重新选
        if let accountID = template.accountID {
            if accounts.contains(where: { $0.id == accountID }) {
                self.accountID = accountID
                if type.isTransfer, toAccountID == accountID {
                    toAccountID = accounts.first { $0.id != accountID }?.id
                }
                filled.insert(.account)
            } else if archivedAccountIDs.contains(accountID) {
                warnings.append("模板里的账户已归档")
            } else {
                warnings.append("模板里的账户已删除")
            }
        }

        // ⑤ 备注：模板定义的是整套表单，所以照填（含"改回空备注"）
        note = template.note

        // ⑥ 日期
        if !hasCustomDay {
            day = today
        }

        templateWarning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
        flash(filled)
    }

    /// 清掉模板降级提示（用户下次操作时调用，避免小字长期挂在那里）。
    func dismissTemplateWarning() {
        templateWarning = nil
    }

    /// 模板写操作失败时的提示（删模板 / 改模板）。
    ///
    /// 走 `templateWarning` 而不是 `errorMessage`：`errorMessage` 会被
    /// `hintBar` 显示成"这笔账存不了"，而模板写失败与这一笔账无关。
    func showTemplateError(_ error: Error) {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            templateWarning = text
        } else {
            templateWarning = "操作失败：\(error.localizedDescription)"
        }
    }

    /// 高亮脉冲：`filled` 里的字段亮 0.3s。
    ///
    /// 用 `Task` 而不是 `withAnimation` 的延迟：连续点两个 chip 时必须**先取消**上一次，
    /// 否则先前的计时器会把新一次的高亮提前清掉（用户看到"第二个 chip 没高亮"）。
    private func flash(_ fields: Set<TemplateField>) {
        flashTask?.cancel()
        guard !fields.isEmpty else {
            templateFlash = []
            return
        }
        templateFlash = fields
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.templateFlash = []
        }
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
