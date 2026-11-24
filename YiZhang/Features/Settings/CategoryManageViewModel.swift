//
//  CategoryManageViewModel.swift
//  一账 / Features / Settings
//
//  职责：分类管理的全部业务（T21）——两个 Tab 的宫格 + 新建 / 编辑 / 排序 / 隐藏 / 删除迁移。
//
//  ## 三条业务铁律（都在这里落地，不散到视图里去）
//
//  ① **预置分类可隐藏不可删**（R-CAT-1）：`isPreset` 的分类删除入口直接抛错，
//     UI 那边也是置灰的——两道防线，因为"置灰"只是渲染，任何一次重构都可能漏掉。
//  ② **删除自定义分类必须迁移账目**（R-CAT-2）：绝不允许产生无分类账目。
//     所以 `deletePreview` 会先说清"这下面有几笔"，`delete(id:migratingTo:)` 在
//     目标为空时直接抛错，而不是"先删了再说"。
//  ③ **分类与账目类型强绑**（R-CAT）：支出分类不能当收入的迁移目标，
//     这里也要挡一次（UI 只列同类型分类，但业务层不能假设 UI 一定对）。
//
//  写入一律走 `environment.writer`：迁移账目 + 删除分类必须落在**同一个 save** 里，
//  否则中途失败会留下"分类没了、账目还指着一个不存在的 id"。
//

import Foundation
import Observation
import SwiftData

/// 分类管理 ViewModel。
@Observable
@MainActor
final class CategoryManageViewModel {

    // MARK: - 行

    /// 宫格里的一格。
    struct Row: Identifiable, Hashable {

        let id: UUID
        let name: String
        let typeRaw: String
        let iconName: String
        let colorHex: String
        /// 预置分类不可删（R-CAT-1）。
        let isPreset: Bool
        let isHidden: Bool
        let sortOrder: Int
        /// 该分类下**未删除**的账目条数。
        let entryCount: Int

        var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

        var canDelete: Bool { !isPreset }

        /// 预置分类删除按钮上的说明文字。
        var deleteHint: String {
            isPreset ? "预置分类不可删除，可隐藏" : (entryCount > 0 ? "删除前需要把 \(entryCount) 笔账目迁移走" : "")
        }
    }

    // MARK: - 删除意图

    /// 删除前必须让用户看到的三种情况。
    enum DeletePreview: Hashable, Sendable {
        /// 预置分类：不可删（UI 置灰 + 说明）。
        case notAllowed(name: String)
        /// 有账目：必须先选迁移目标。
        case requiresMigration(name: String, entryCount: Int)
        /// 无账目：直接删。
        case direct(name: String)

        var canProceed: Bool {
            if case .notAllowed = self { return false }
            return true
        }

        var message: String {
            switch self {
            case .notAllowed(let name):
                return "「\(name)」是预置分类，不可删除。可以把它隐藏起来。"
            case .requiresMigration(let name, let count):
                return "「\(name)」下有 \(count) 笔账目，删除前请选择迁移到哪个分类。"
            case .direct(let name):
                return "「\(name)」下没有任何账目，删除后无法恢复。"
            }
        }
    }

    /// 删除结果。
    enum DeleteOutcome: Hashable, Sendable {
        case deleted
        case migrated(entryCount: Int)
    }

    // MARK: - 状态

    private(set) var expenseRows: [Row] = []
    private(set) var incomeRows: [Row] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    @ObservationIgnored
    private var environment: AppEnvironment?

    // MARK: - 加载

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    func load() {
        guard let environment else { return }
        do {
            expenseRows = try makeRows(environment, type: .expense)
            incomeRows = try makeRows(environment, type: .income)
            errorMessage = nil
        } catch {
            expenseRows = []
            incomeRows = []
            errorMessage = "分类读取失败：\(error.localizedDescription)。退出这一页再进来可以重试。"
        }
        isLoaded = true
    }

    func rows(for type: EntryType) -> [Row] {
        switch type {
        case .expense: return expenseRows
        case .income: return incomeRows
        case .transfer: return []
        }
    }

    /// 记账页选择器该用的列表（隐藏的不出现）。
    func selectableRows(for type: EntryType) -> [Row] {
        rows(for: type).filter { !$0.isHidden }
    }

    /// 迁移目标候选：同类型、不是自己、可见优先（隐藏分类仍可作为目标，但排在后面）。
    func migrationTargets(for id: UUID, type: EntryType) -> [Row] {
        rows(for: type)
            .filter { $0.id != id }
            .sorted { lhs, rhs in
                if lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    // MARK: - 新建 / 编辑

    @discardableResult
    func create(
        name: String,
        type: EntryType,
        iconName: String,
        colorHex: String
    ) throws -> UUID {
        guard let environment else { throw CategoryManageError.notReady }
        guard type != .transfer else { throw CategoryManageError.invalidType }
        let trimmed = try validatedName(name, type: type, excluding: nil)

        let category = Category()
        category.id = UUID()
        category.name = trimmed
        category.type = type
        category.iconName = PresetCatalog.sanitizedSymbolName(iconName)
        category.colorHex = colorHex
        category.isPreset = false
        category.isHidden = false
        category.sortOrder = (rows(for: type).map(\.sortOrder).max() ?? -1) + 1
        let now = Date()
        category.createdAt = now
        category.updatedAt = now

        do {
            try environment.writer.insert(category)
        } catch {
            environment.writer.rollback()
            throw CategoryManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
        return category.id
    }

    func update(id: UUID, name: String, iconName: String, colorHex: String) throws {
        guard let environment else { throw CategoryManageError.notReady }
        guard let category = try environment.writer.category(id: id) else {
            throw CategoryManageError.notFound
        }
        let trimmed = try validatedName(name, type: category.type, excluding: id)

        do {
            try environment.writer.update(category) { model in
                model.name = trimmed
                model.iconName = PresetCatalog.sanitizedSymbolName(iconName)
                model.colorHex = colorHex
                model.updatedAt = Date()
            }
        } catch {
            environment.writer.rollback()
            throw CategoryManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
    }

    /// 隐藏 / 取消隐藏（预置分类唯一的"下线"方式）。
    func setHidden(_ hidden: Bool, for id: UUID) throws {
        guard let environment else { throw CategoryManageError.notReady }
        guard let category = try environment.writer.category(id: id) else {
            throw CategoryManageError.notFound
        }

        do {
            try environment.writer.update(category) { model in
                model.isHidden = hidden
                model.updatedAt = Date()
            }
        } catch {
            environment.writer.rollback()
            throw CategoryManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
    }

    // MARK: - 删除

    /// 删除前的弹窗判据。
    ///
    /// **计数必须与 `performDelete` 同口径**（用同一个 `referencingEntryCount`，
    /// 都含软删账目）。两处各数一套就会出 P3 那种死路：
    /// 弹窗按"只数未删"说「没有任何账目」→ 不给「迁移到」区 → 点删除却抛
    /// `migrationTargetRequired` → 弹窗里无处可选，这个分类永远删不掉。
    func deletePreview(for id: UUID) -> DeletePreview? {
        guard let environment, let row = allRows.first(where: { $0.id == id }) else { return nil }
        if row.isPreset { return .notAllowed(name: row.name) }
        // 读取失败时退回页面快照：此处抛错意味着库本身读不出来，
        // 真删除会在自己的 fetch 上同样失败，不会因此删错东西。
        let count = (try? referencingEntryCount(categoryID: id, in: environment)) ?? row.entryCount
        if count > 0 { return .requiresMigration(name: row.name, entryCount: count) }
        return .direct(name: row.name)
    }

    /// 删除分类；有账目时必须给 `migratingTo`。
    ///
    /// - Parameters:
    ///   - id: 待删分类。
    ///   - migratingTo: 迁移目标（`nil` 表示"该分类下没有账目"）。
    /// - Returns: `.deleted` 或 `.migrated(count)`。
    @discardableResult
    func delete(id: UUID, migratingTo targetID: UUID? = nil) throws -> DeleteOutcome {
        guard let environment else { throw CategoryManageError.notReady }
        // 预置判定走库里的真相（R-CAT-1：可隐藏、不可删除），不读 UI 快照——
        // 快照过期时"预置"这一栏也可能读错，而这条是不可逆操作的守卫。
        guard let category = try environment.writer.category(id: id) else {
            throw CategoryManageError.notFound
        }
        guard !category.isPreset else { throw CategoryManageError.presetNotDeletable }

        return try performDelete(id: id, migratingTo: targetID, environment: environment)
    }

    /// 删除的实际分支。
    ///
    /// **判据是现数，不是 `deletePreview` 的快照**：
    /// `allRows` 只在 `attach()` 与自身写操作后刷新，页面存活期间的外部写入
    /// （回前台 sweep 落订阅账目是最真实的一条路径）看不到，旧值 0 会让
    /// "有账目的分类"走进 `.direct` 真删分支，留下 `category == nil` 的账目
    /// ——这直接违反 R-CAT-2（不允许无分类账目）。
    ///
    /// 计数口径与 `deletePreview` **完全同一个函数**（`referencingEntryCount`）。
    private func performDelete(
        id: UUID,
        migratingTo targetID: UUID?,
        environment: AppEnvironment
    ) throws -> DeleteOutcome {
        let entries: [LedgerEntry]
        do {
            entries = try referencingEntries(categoryID: id, in: environment)
        } catch {
            throw CategoryManageError.saveFailed(error.localizedDescription)
        }

        let referencingCount = entries.count

        if referencingCount == 0 {
            guard let category = try environment.writer.category(id: id) else {
                throw CategoryManageError.notFound
            }
            do {
                try environment.writer.delete(category)
            } catch {
                environment.writer.rollback()
                throw CategoryManageError.saveFailed(error.localizedDescription)
            }
            finishWrite()
            return .deleted
        }

        let count = referencingCount
        do {
            guard let targetID else { throw CategoryManageError.migrationTargetRequired }
            guard let source = try environment.writer.category(id: id) else {
                throw CategoryManageError.notFound
            }
            guard source.id != targetID else { throw CategoryManageError.migrationTargetIsSelf }
            guard let target = try environment.writer.category(id: targetID) else {
                throw CategoryManageError.notFound
            }
            // R-CAT：支出账目不能迁到收入分类下，否则统计口径会瞬间错位
            guard target.type == source.type else {
                throw CategoryManageError.migrationTypeMismatch
            }

            let moved = migrate(entries, to: target)
            do {
                try environment.writer.delete(source, save: false)
                try environment.writer.save()
            } catch {
                environment.writer.rollback()
                throw CategoryManageError.saveFailed(error.localizedDescription)
            }
            finishWrite()
            return .migrated(entryCount: moved == 0 ? count : moved)
        } catch let error as CategoryManageError {
            throw error
        } catch {
            environment.writer.rollback()
            throw CategoryManageError.saveFailed(error.localizedDescription)
        }
    }

    /// 把一批账目改挂到目标分类（不 save，由调用方与删除合并成一个事务）。
    ///
    /// 入参是调用方**现数**出来的账目数组：计数与迁移必须来自同一批对象，
    /// 否则会出现"数到 3 笔、只迁了 0 笔"的分类错位（P2 的第二种死法）。
    private func migrate(_ entries: [LedgerEntry], to target: Category) -> Int {
        var moved = 0
        let now = Date()
        for entry in entries {
            entry.category = target
            entry.updatedAt = now
            moved += 1
        }
        return moved
    }

    // MARK: - 排序

    /// 拖拽排序：把 `id` 移到同类型序列的第 `toIndex` 位。
    func move(id: UUID, toIndex destination: Int, type: EntryType) throws {
        guard let environment else { throw CategoryManageError.notReady }
        var reordered = rows(for: type)
        guard let currentIndex = reordered.firstIndex(where: { $0.id == id }) else {
            throw CategoryManageError.notFound
        }
        let moved = reordered.remove(at: currentIndex)
        let target = min(max(destination, 0), reordered.count)
        reordered.insert(moved, at: target)

        do {
            for (index, row) in reordered.enumerated() {
                guard let category = try environment.writer.category(id: row.id) else { continue }
                guard category.sortOrder != index else { continue }
                category.sortOrder = index
                category.updatedAt = Date()
            }
            try environment.writer.save()
        } catch {
            environment.writer.rollback()
            throw CategoryManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 私有

    private var allRows: [Row] { expenseRows + incomeRows }

    /// 写入成功后的收尾：**先广播，再刷自己**。
    ///
    /// 为什么必须广播（R2）：分类名会被 `EntryRowModel.categoryName` 与统计的
    /// 分类占比以字符串快照拷走，只有 `dataVersion` 变了那些页面才重算。本类直接
    /// 拿 `writer` 改数据、绕过了 4 个 Service 的 `onDidCommit`，不补这一下，
    /// 改完分类名返回账本 / 统计，看到的还是旧名。
    ///
    /// 反过来**不给 `writer` 加全局回调**：那会让 Service 的写入被广播两次。
    ///
    /// `load()` 自己**不**广播——它是纯读取，广播会 `.task(id: dataVersion)` 自激。
    private func finishWrite() {
        environment?.bumpDataVersion()
        load()
    }

    /// 该分类下**所有**引用它的账目（未删 + 已删）。
    ///
    /// 这是删除判据的**唯一口径来源**：`deletePreview`（弹窗里说什么）与
    /// `performDelete`（真删还是要求迁移）都调它，不给"两处各数一套"留缝。
    ///
    /// 为什么要含**软删**账目：软删是可撤销、可恢复的，硬删掉它引用的分类，
    /// 恢复出来就是一条无分类账目（R-CAT-2）。
    ///
    /// 为什么不用关系谓词 / 关系数组：
    /// - `$0.category?.id == id` 是 iOS 17 的崩溃面（R10），所以拉「未删 + 已删」
    ///   两批（纯标量谓词）在内存里筛；
    /// - `category.entries` 是这个 context 里已 materialize 的关系数组，页面存活
    ///   期间新写入的账目不在里面——用它迁移会"迁移 0 笔、然后删掉分类"。
    private func referencingEntries(
        categoryID id: UUID,
        in environment: AppEnvironment
    ) throws -> [LedgerEntry] {
        let live = try environment.writer.fetch(
            FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.deletedAt == nil })
        )
        let deleted = try environment.writer.fetch(
            FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.deletedAt != nil })
        )
        return (live + deleted).filter { $0.category?.id == id }
    }

    /// `referencingEntries` 的计数封装（`deletePreview` 只需要个数，不需要对象）。
    private func referencingEntryCount(
        categoryID id: UUID,
        in environment: AppEnvironment
    ) throws -> Int {
        try referencingEntries(categoryID: id, in: environment).count
    }

    /// 名称校验：非空 + 同类型内唯一（含隐藏分类，否则取消隐藏时会撞名）。
    private func validatedName(_ name: String, type: EntryType, excluding excludedID: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CategoryManageError.emptyName }
        let clash = rows(for: type).contains { row in
            row.id != excludedID && row.name == trimmed
        }
        guard !clash else { throw CategoryManageError.duplicateName(trimmed) }
        return trimmed
    }

    private func makeRows(_ environment: AppEnvironment, type: EntryType) throws -> [Row] {
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: type))

        // 一次扫描统计各分类的账目数（含只有在"未删除"时才计入）
        let entries = try environment.writer.fetch(QueryDescriptors.allEntries())
        var counts: [UUID: Int] = [:]
        for entry in entries where entry.deletedAt == nil {
            guard let categoryID = entry.category?.id else { continue }
            counts[categoryID, default: 0] += 1
        }

        return categories
            .map { category in
                Row(
                    id: category.id,
                    name: category.name,
                    typeRaw: category.typeRaw,
                    iconName: category.iconName,
                    colorHex: category.colorHex,
                    isPreset: category.isPreset,
                    isHidden: category.isHidden,
                    sortOrder: category.sortOrder,
                    entryCount: counts[category.id] ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.name < rhs.name
            }
    }
}

// MARK: - 错误

/// 分类操作错误。
enum CategoryManageError: LocalizedError, Hashable {
    case notReady
    case emptyName
    case duplicateName(String)
    case notFound
    case invalidType
    case presetNotDeletable
    case migrationTargetRequired
    case migrationTargetIsSelf
    case migrationTypeMismatch
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "数据还没准备好，请稍后再试"
        case .emptyName:
            return "分类名称不能为空"
        case .duplicateName(let name):
            return "已经有叫「\(name)」的分类了"
        case .notFound:
            return "找不到这个分类，可能已被删除"
        case .invalidType:
            return "分类只能是支出或收入"
        case .presetNotDeletable:
            return "预置分类不可删除，可以隐藏"
        case .migrationTargetRequired:
            return "这个分类下有账目，请先选择迁移目标"
        case .migrationTargetIsSelf:
            return "不能迁移到自己"
        case .migrationTypeMismatch:
            return "只能迁移到同类型的分类"
        case .saveFailed(let reason):
            return "保存失败：\(reason)"
        }
    }
}
