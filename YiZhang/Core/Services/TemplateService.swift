//
//  TemplateService.swift
//  一账 / Core / Services
//
//  职责：常用记账模板（V1.1 / F-ACC-14 / PRD §5）的全部用例。
//
//  分层位置：`View → ViewModel → TemplateService → LedgerWriter → SwiftData`。
//  本层允许 `import SwiftData`（要引用 `@Model` 类型），禁止 `import SwiftUI`，
//  也**禁止自己调 `context.save()`**——提交一律经 `LedgerWriter`（A3 铁律）。
//
//  ## 为什么模板的所有写操作都必须经过本类
//
//  PRD 5.3-1 的「上限 20 条」、5.2 的「名字 ≤20 字 / 备注 ≤100 字」、
//  「不支持转账」这三条约束，只有在一处实现才不会漏。模板是一张**纯输入辅助表**，
//  校验成本极低，但一旦漏掉上限校验，用户就能造出 200 个 chip 把记账页挤成横向瀑布。
//
//  ## 为什么模板与账目零引用（PRD 5.3-5）
//
//  账目里**不存 `templateID`**。于是「删模板」不可能影响任何已有账目，
//  「改模板」也不可能改到历史数据。这条边界不是疏漏，是刻意设计：
//  模板是"输入快捷键"，不是"数据源"，一旦让它们产生引用关系，
//  「删模板要不要问用户」「改模板要不要回写历史账目」这类问题就会永久跟着这个功能。
//
//  ## 为什么分类 / 账户解析失败不抛错（PRD 5.3-4）
//
//  模板可以比分类/账户活得更久：账户被归档、分类被删（V1.0 已做强制迁移，
//  实际只会遇到归档）时，模板不该变成一个"点一下就报错"的按钮。
//  正确行为是**逐字段降级**：解析不到的字段置 nil，UI 少填一个字段并给一行小字提示，
//  模板本身继续可用。所以本类对 `categoryID` / `accountID` 只做「能解析就挂上」。
//

import Foundation
import SwiftData

// MARK: - 错误

/// 模板相关的业务错误。全部带中文 `errorDescription`，UI 可直接展示。
enum TemplateError: LocalizedError, Equatable {
    /// 已满 20 条（PRD 5.3-1）
    case limitReached
    /// 名字为空（去掉首尾空白后）
    case nameEmpty
    /// 名字超过 20 字
    case nameTooLong

    var errorDescription: String? {
        switch self {
        case .limitReached: return "最多 20 个模板，先删一个"
        case .nameEmpty: return "请给模板起个名字"
        case .nameTooLong: return "模板名最多 20 字"
        }
    }
}

// MARK: - 值类型

/// 新建 / 编辑模板的入参。
///
/// 用 `categoryID` / `accountID` 而不是模型对象：调用方（ViewModel）手里只有 id，
/// 而且**解析必须是本类的责任**——解析不到要静默置 nil，这个决定不该散落到 UI 里。
///
/// 全部字段带默认值，于是 `TemplateDraft()` 就是一个"空草稿"，
/// 表单初始状态不需要手写一堆 `= nil`。
struct TemplateDraft: Sendable, Equatable {

    /// 模板名（≤ `TemplateService.nameLimit` 字，非空）。
    var name: String = ""

    /// `EntryType` 的 raw 值。只允许 expense / income（模板不支持转账）。
    var typeRaw: String = EntryType.expense.raw

    /// 预设金额（分）。`hasAmount == false` 时此值不被使用。
    var amount: Int64 = 0

    /// 是否预设金额。`false` = 金额留给用户当天输入（PRD 5.3-2 的主力用法）。
    var hasAmount: Bool = false

    /// 备注（≤ 100 字，可空）。
    var note: String = ""

    /// 预设分类；`nil` = 没有。
    var categoryID: UUID? = nil

    /// 预设账户；`nil` = 没有。
    var accountID: UUID? = nil

    init(
        name: String = "",
        typeRaw: String = EntryType.expense.raw,
        amount: Int64 = 0,
        hasAmount: Bool = false,
        note: String = "",
        categoryID: UUID? = nil,
        accountID: UUID? = nil
    ) {
        self.name = name
        self.typeRaw = typeRaw
        self.amount = amount
        self.hasAmount = hasAmount
        self.note = note
        self.categoryID = categoryID
        self.accountID = accountID
    }

    /// 账目类型（未知 raw 按支出处理，与 `EntryTemplate.type` 口径一致）。
    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }
}

// MARK: - 服务

/// 模板服务：列表、新建、编辑、删除、排序、从历史账目复制。
@MainActor
final class TemplateService {

    /// 模板数量上限（PRD 5.3-1）。
    ///
    /// 20 的依据是交互：chips 一行只放 3–4 个，再多了要横滑，
    /// 而模板的价值就在"一眼点到"；20 是"仍能横滑找到"的上限。
    static let limit = 20

    /// 名字长度上限（PRD 5.2）。
    static let nameLimit = 20

    /// 备注长度上限（与账目备注同口径，PRD 5.2）。
    static let noteLimit = 100

    private let writer: LedgerWriter

    /// 写入提交后的回调（由 `AppEnvironment` 接到 `bumpDataVersion()`）。
    ///
    /// 用回调而不是让 Service 反向持有 `AppEnvironment`：避免循环引用，
    /// 也让本类可以在测试里独立构造（回调留空即可）。
    var onDidCommit: (() -> Void)?

    init(writer: LedgerWriter, onDidCommit: (() -> Void)? = nil) {
        self.writer = writer
        self.onDidCommit = onDidCommit
    }

    // MARK: - 读

    /// 全部模板，按「手动排序 → 创建时间 → id」升序。
    ///
    /// 为什么第三级要用 `id`：拖拽排序会把一批 `sortOrder` 重写成 0..n，
    /// 但历史数据里可能存在多个相同的 `sortOrder`（早期版本写入、或批量导入）。
    /// 没有第三级时，`SortDescriptor` 的顺序在两次 `fetch` 之间**不保证稳定**，
    /// chip 会在重进页面时悄悄换位（PRD 5.3-6 明确禁止随机换位）。
    ///
    /// 排序在内存里做而不是交给 `SortDescriptor`：`UUID` 不满足 `Comparable`，
    /// 拿它做 `SortDescriptor` 键会退化成 NSObject 版本并编译失败。
    func all() throws -> [EntryTemplate] {
        let templates = try writer.fetch(TemplateService.allDescriptor())
        return TemplateService.sorted(templates)
    }

    /// 模板总数（设置页「记账模板 3/20」与「＋」置灰判定用）。
    func count() throws -> Int {
        try writer.count(TemplateService.countDescriptor())
    }

    /// 是否还能再建一个（UI 置灰用；真正的拦截在 `create`）。
    func canCreate() throws -> Bool {
        try count() < TemplateService.limit
    }

    // MARK: - 写

    /// 新建模板。
    ///
    /// - Parameter draft: 表单填写的草稿。
    /// - Returns: 新插入的模板。
    /// - Throws: `.limitReached` / `.nameEmpty` / `.nameTooLong`。
    @discardableResult
    func create(_ draft: TemplateDraft) throws -> EntryTemplate {
        guard try count() < TemplateService.limit else { throw TemplateError.limitReached }
        let prepared = try validated(draft)

        let now = Date()
        let model = EntryTemplate()
        model.id = UUID()
        model.name = prepared.name
        model.typeRaw = prepared.typeRaw
        model.amount = prepared.amount
        model.hasAmount = prepared.hasAmount
        model.note = prepared.note
        model.sortOrder = try nextSortOrder()
        model.createdAt = now
        model.updatedAt = now

        try writer.insert(model)
        // 关系必须在同一个 context 里解析成托管对象；解析不到就留 nil（PRD 5.3-4）
        try writer.update(model) { target in
            target.category = try writer.category(id: prepared.categoryID)
            target.account = try writer.account(id: prepared.accountID)
        }

        onDidCommit?()
        return model
    }

    /// 编辑模板（整份草稿替换，不做"只改某字段"）。
    ///
    /// 为什么整份替换：模板只有 7 个业务字段，表单本来就是全量提交；
    /// 用 `nil = 不改` 的增量语义会让"清空备注"表达不出来（`nil` 二义）。
    ///
    /// - Parameters:
    ///   - id: 模板 id。
    ///   - draft: 新内容。
    /// - Throws: 校验失败。
    func update(id: UUID, changing draft: TemplateDraft) throws {
        // 模板已被另一处删掉：静默返回（与 `delete` 同口径）。
        // 编辑一个不存在的模板不该弹错——用户的意图已经无法执行，报错只增加困惑。
        guard let model = try template(id: id) else { return }
        let prepared = try validated(draft)

        try writer.update(model) { target in
            target.name = prepared.name
            target.typeRaw = prepared.typeRaw
            target.amount = prepared.amount
            target.hasAmount = prepared.hasAmount
            target.note = prepared.note
            target.category = try writer.category(id: prepared.categoryID)
            target.account = try writer.account(id: prepared.accountID)
            target.updatedAt = Date()
        }
        onDidCommit?()
    }

    /// 删除模板（PRD 5.3-5：不影响任何已生成账目——模板与账目零引用）。
    ///
    /// 删除后**不重排**剩余模板的 `sortOrder`：留下的空号不影响排序正确性
    /// （排序只看相对大小），重排反而会让"撤销删除"无法还原原位置。
    /// 真正的顺序整理发生在下一次 `reorder(orderedIDs:)`。
    func delete(id: UUID) throws {
        guard let model = try template(id: id) else { return }
        try writer.delete(model)
        onDidCommit?()
    }

    /// 按给定顺序重写 `sortOrder`（拖拽结束调用）。
    ///
    /// 一次 `save()`：整批 `sortOrder` 必须同时生效，否则拖拽过程中
    /// 若发生崩溃，用户会看到"一半新顺序、一半旧顺序"的中间态。
    ///
    /// - Parameter orderedIDs: 从头到尾的模板 id 顺序。
    func reorder(orderedIDs: [UUID]) throws {
        guard !orderedIDs.isEmpty else { return }
        // 先取全部模板，避免每改一个都去 fetch 一次
        let existing = try writer.fetch(TemplateService.allDescriptor())
        var byID: [UUID: EntryTemplate] = [:]
        for model in existing {
            byID[model.id] = model
        }

        let now = Date()
        var didChange = false
        for (index, id) in orderedIDs.enumerated() {
            guard let model = byID[id] else { continue }
            if model.sortOrder == index { continue }
            // save: false —— 整批写完后统一提交
            try writer.update(model, save: false) { target in
                target.sortOrder = index
                target.updatedAt = now
            }
            didChange = true
        }

        guard didChange else { return }
        try writer.save()
        onDidCommit?()
    }

    /// 从一笔历史账目复制成模板（PRD 5.3-3，最高频的创建路径）。
    ///
    /// `hasAmount` 跟随原账目：金额 > 0 则 `true`。
    /// 转账账目不允许存成模板（模板不支持转账），因此类型会被收敛成支出——
    /// 但**金额、备注、账户仍保留**，用户改一下类型就能用，不至于白点一次。
    ///
    /// - Parameters:
    ///   - entryID: 源账目 id。
    ///   - name: 模板名（UI 默认填备注或分类名，用户可改）。
    /// - Returns: 新插入的模板。
    @discardableResult
    func makeFrom(entryID: UUID, name: String) throws -> EntryTemplate {
        // 源账目不存在：复用 `LedgerError.entryNotFound` 而不是给 `TemplateError`
        // 加第四个 case —— T5 的界面会按三个 case 穷举写文案，多一个 case 会让它编译不过。
        guard let entry = try writer.entry(id: entryID) else { throw LedgerError.entryNotFound }

        let fallbackName = name.isEmpty
            ? (entry.note.isEmpty ? (entry.category?.displayName ?? "") : entry.note)
            : name

        let draft = TemplateDraft(
            name: fallbackName,
            typeRaw: TemplateService.templatableType(entry.type).raw,
            amount: entry.amount,
            hasAmount: entry.amount > 0,
            note: entry.note,
            categoryID: entry.category?.id,
            accountID: entry.account?.id
        )
        return try create(draft)
    }

    // MARK: - 内部

    /// 单条查询（本文件私有：外部只按 id 改，不需要拿模型）。
    private func template(id: UUID) throws -> EntryTemplate? {
        var descriptor = FetchDescriptor<EntryTemplate>(
            predicate: #Predicate<EntryTemplate> { model in model.id == id }
        )
        descriptor.fetchLimit = 1
        return try writer.fetch(descriptor).first
    }

    /// 下一个 `sortOrder`（追加到末尾）。
    private func nextSortOrder() throws -> Int {
        let templates = try writer.fetch(TemplateService.allDescriptor())
        return (templates.map(\.sortOrder).max() ?? -1) + 1
    }

    /// 校验并把草稿规整成可直接落库的形态。
    ///
    /// 三条规整：
    /// ① 名字去首尾空白后判空 / 判长；
    /// ② 类型收敛到 expense / income（转账模板表达不出来，见文件头注释）；
    /// ③ 备注超长按 100 字截断——PRD 5.2 给了长度约束但**没有给错误态**，
    ///    为一个输入框的粘贴超长弹错误弹窗不值得，而 UI 输入框本身已限长。
    private func validated(_ draft: TemplateDraft) throws -> TemplateDraft {
        var prepared = draft
        prepared.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.name.isEmpty else { throw TemplateError.nameEmpty }
        guard prepared.name.count <= TemplateService.nameLimit else { throw TemplateError.nameTooLong }

        prepared.typeRaw = TemplateService.templatableType(draft.type).raw
        prepared.note = String(draft.note.prefix(TemplateService.noteLimit))
        // 金额留空时把值也清零：避免"hasAmount = false 但 amount 带着上一次的 25 元"
        // 这种记录被将来的某条路径误用（脏数据比缺字段更难查）。
        if !prepared.hasAmount {
            prepared.amount = 0
        }
        if prepared.amount < 0 {
            prepared.amount = 0
        }
        return prepared
    }

    /// 模板能表达的类型：只有支出与收入。
    private static func templatableType(_ type: EntryType) -> EntryType {
        switch type {
        case .expense: return .expense
        case .income: return .income
        case .transfer: return .expense
        }
    }

    /// 内存排序：`sortOrder` ↑ → `createdAt` ↑ → `id` 升序（PRD 5.3-6 的稳定性要求）。
    private static func sorted(_ templates: [EntryTemplate]) -> [EntryTemplate] {
        templates.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 全量模板查询。
    ///
    /// 刻意不放进 `QueryDescriptors`：那份文件的职责是"账目/账户/分类/订阅/待办"
    /// 这些**既有查询域**的唯一来源（改它会牵动 484 个既有测试的假设）。
    /// 模板是本批新建的独立小表（≤ 20 行），谓词全为空，没有复用的价值。
    private static func allDescriptor() -> FetchDescriptor<EntryTemplate> {
        FetchDescriptor<EntryTemplate>()
    }

    /// 计数查询（空谓词，走 `fetchCount`）。
    private static func countDescriptor() -> FetchDescriptor<EntryTemplate> {
        FetchDescriptor<EntryTemplate>()
    }
}
