//
//  TemplateManageViewModel.swift
//  一账 / Features / Settings
//
//  职责：模板管理页（V1.1 F-ACC-14）的列表状态与全部写操作。
//
//  ## 为什么这一页几乎没有业务规则
//
//  上限 20、名字 ≤20 字、备注 ≤100 字、「不留金额就把金额清零」这些全在
//  `TemplateService` 里——本类**不重复实现任何一条**，只负责：
//  ① 把 `@Model EntryTemplate` 翻译成值类型 `TemplateOption`（View 不碰模型）；
//  ② 拖拽 → `move(from:to:)`（算出完整顺序后交服务层整批提交）；
//  ③ 写失败时把中文文案留在 `errorMessage` 上。
//
//  ## 为什么排序要整批提交
//
//  一次拖拽会改动一批 `sortOrder`。逐条提交会出现"前三条已按新顺序、后两条还是旧顺序"
//  的中间态（此时如果 App 被系统杀掉，用户重进会看到一段错位的 chips）。
//  `TemplateService.reorder` 内部已经是 `save: false` 循环 + 末尾一次 `save()`，
//  本类只需要把"从头到尾的 id 数组"交过去。
//

import Foundation
import Observation

/// 环境尚未注入时的兜底错误（正常路径下 `attach` 必在用户可点之前完成，
/// 这条只防"预览里直接点了保存"这类开发期误用）。
private enum TemplateManageError: LocalizedError {
    case notReady
    var errorDescription: String? { "数据还没准备好，请稍后再试" }
}

/// 模板管理页的视图模型。
@Observable
@MainActor
final class TemplateManageViewModel {

    // MARK: - 只读状态

    /// 全部模板，顺序 = `TemplateService.all()` 的顺序（不重排）。
    private(set) var templates: [TemplateOption] = []

    /// 是否还能再建一个（满 20 时右上「＋」置灰）。
    private(set) var canCreate = true

    /// 写失败提示。
    private(set) var errorMessage: String?

    /// 首帧防闪。
    private(set) var isLoaded = false

    // MARK: - 展示用的查找表

    /// 分类 id → 名称（模板只存 id，列表要显示名字）。
    private(set) var categoryNames: [UUID: String] = [:]
    /// 分类 id → SF Symbol。
    private(set) var categoryIcons: [UUID: String] = [:]
    /// 账户 id → 名称（含归档账户，行里要能显示「（已归档）」）。
    private(set) var accountNames: [UUID: String] = [:]
    /// 已归档账户 id（行尾标一句提示，PRD 5.3-4）。
    private(set) var archivedAccountIDs: Set<UUID> = []

    // MARK: - 依赖

    private var environment: AppEnvironment?

    // MARK: - 常量

    /// 上限（与 `TemplateService.limit` 同一常量，不在本文件写 20）。
    var limit: Int { TemplateService.limit }

    // MARK: - 生命周期

    /// 注入依赖并加载。
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    /// 重新读取列表。
    func load() {
        guard let environment else { return }
        do {
            templates = try environment.template.all().map(TemplateOption.init)
            canCreate = try environment.template.canCreate()
            errorMessage = nil
        } catch {
            errorMessage = "读取模板失败：\(error.localizedDescription)。退出这一页再进来可以重试。"
        }
        reloadLookups(environment)
        isLoaded = true
    }

    /// 分类 / 账户的查找表。
    ///
    /// 单独一个方法并且**吞掉异常**：模板列表能读出来就该能显示，
    /// 不能因为"顺便查分类名失败"让整页变成错误页——名字缺了顶多少显示一行副标题。
    private func reloadLookups(_ environment: AppEnvironment) {
        let expense = (try? environment.readContext
            .fetch(QueryDescriptors.categories(of: .expense, includeHidden: true))) ?? []
        let income = (try? environment.readContext
            .fetch(QueryDescriptors.categories(of: .income, includeHidden: true))) ?? []
        var names: [UUID: String] = [:]
        var icons: [UUID: String] = [:]
        for category in expense + income {
            names[category.id] = category.displayName
            icons[category.id] = category.displayIconName
        }
        categoryNames = names
        categoryIcons = icons

        let accounts = (try? environment.readContext
            .fetch(QueryDescriptors.accounts(includeArchived: true))) ?? []
        accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.displayName) })
        archivedAccountIDs = Set(accounts.filter(\.isArchived).map(\.id))
    }

    // MARK: - 展示辅助

    /// 分类图标；模板没指定分类（或分类已被删）时给中性图标。
    func iconName(for template: TemplateOption) -> String {
        guard let categoryID = template.categoryID else { return "tag" }
        return categoryIcons[categoryID] ?? "tag"
    }

    /// 「餐饮 · 微信」/「餐饮 · 未指定账户」/「餐饮 · 微信（已归档）」。
    func subtitle(for template: TemplateOption) -> String {
        var parts: [String] = []
        if let categoryID = template.categoryID, let name = categoryNames[categoryID] {
            parts.append(name)
        }
        if let accountID = template.accountID, let name = accountNames[accountID] {
            parts.append(archivedAccountIDs.contains(accountID) ? "\(name)（已归档）" : name)
        } else {
            parts.append("不指定账户")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 派生数据

    /// 「3/20」。
    var countText: String { "\(templates.count)/\(limit)" }

    /// 满额时的一句话（页脚用；未满返回 nil）。
    var limitHint: String? {
        canCreate ? nil : TemplateError.limitReached.errorDescription
    }

    /// 是否允许排序（少于 2 条时排序按钮没有意义）。
    var canReorder: Bool { templates.count > 1 }

    // MARK: - 写

    /// 新建模板。
    ///
    /// - Throws: `TemplateError`（上限 / 名字），文案由表单展示。
    func create(_ draft: TemplateDraft) throws {
        guard let environment else { throw TemplateManageError.notReady }
        try environment.template.create(draft)
        finishWrite()
    }

    /// 编辑模板（整份替换，与 `TemplateService.update` 同语义）。
    ///
    /// 模板已被另一处删掉时服务会静默返回——这里也**不报错**，
    /// 只是列表会少一行，用户看到的是"它不见了"，而不是一个无法处理的错误。
    func update(id: UUID, changing draft: TemplateDraft) throws {
        guard let environment else { throw TemplateManageError.notReady }
        try environment.template.update(id: id, changing: draft)
        finishWrite()
    }

    /// 删除模板（PRD 5.3-5：不影响任何已生成的账目）。
    func delete(id: UUID) throws {
        guard let environment else { return }
        try environment.template.delete(id: id)
        finishWrite()
    }

    /// 删除若干条（`onDelete` 给的是下标集合）。
    func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            templates.indices.contains(index) ? templates[index].id : nil
        }
        guard !ids.isEmpty else { return }
        do {
            for id in ids {
                try environment?.template.delete(id: id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        load()
    }

    /// 拖拽排序：`List` 的 `onMove` 语义（`destination` 是**移动前**的插入位置）。
    func move(from source: IndexSet, to destination: Int) {
        var ordered = templates
        let moving = source.compactMap { ordered.indices.contains($0) ? ordered[$0] : nil }
        guard !moving.isEmpty else { return }
        // 从后往前删，避免前面的删除让后面的下标失效
        for index in source.sorted(by: >) where ordered.indices.contains(index) {
            ordered.remove(at: index)
        }
        // `destination` 以原数组为基准，因此要先减掉"落在它前面且被移走的个数"
        let removedBefore = source.filter { $0 < destination }.count
        let insertAt = max(0, min(ordered.count, destination - removedBefore))
        ordered.insert(contentsOf: moving, at: insertAt)

        templates = ordered
        persistOrder(ordered.map(\.id))
    }

    /// 清掉错误提示。
    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 内部

    private func persistOrder(_ orderedIDs: [UUID]) {
        guard let environment else { return }
        do {
            try environment.template.reorder(orderedIDs: orderedIDs)
            errorMessage = nil
        } catch {
            errorMessage = "保存顺序失败：\(error.localizedDescription)"
        }
        // 无论成功与否都重读一次：失败时把界面拉回数据库里的真实顺序，
        // 而不是让 UI 停在一个"看起来改好了、其实没存"的状态。
        load()
    }

    /// 写完统一重读：`sortOrder` / `updatedAt` 都变了，本地拼是第二份实现。
    private func finishWrite() {
        load()
    }
}
