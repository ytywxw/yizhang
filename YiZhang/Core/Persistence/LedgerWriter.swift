//
//  LedgerWriter.swift
//  一账 / Core / Persistence
//
//  职责：**全项目唯一持有并写 `ModelContext` 的地方**（A3 铁律）。
//
//  为什么必须唯一：
//  ① SwiftData 的"事务"就是"同一个 context 的 pending changes 一次 `save()`"，
//     一旦有两个 context 并发写，就再也没有原子性可言（跨 context 没有 begin/commit）；
//  ② 幂等第 2 层要求"先查后插"能看到同批次的 pending changes（`includePendingChanges`），
//     只有同一个 context 才成立；
//  ③ iOS 17 的后台 context 写入不会可靠地触发 `@Query` 刷新（R6），所以写入一律在 MainActor。
//
//  幂等第 2 层的实现（架构 §3.3）：
//  ```swift
//  var descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.sourceCycleUniqueKey == key })
//  descriptor.fetchLimit = 1
//  descriptor.includePendingChanges = true     // ← 关键：未提交的插入也算
//  if try context.fetchCount(descriptor) > 0 { return .skippedDuplicate(key) }
//  ```
//  第 1 层是"单写入口"（本类），第 3 层是启动自检（`Diagnostics`）。
//
//  本类**禁止包含业务规则**：不判断"支出必须有分类"、不推进订阅日期——那是 `LedgerService`
//  与 `SweepCoordinator` 的事。这里只负责"安全地落库"。
//

import Foundation
import SwiftData

/// 一次插入的结果。
enum InsertOutcome: Hashable, Sendable {
    /// 已插入，携带新账目的 id。
    case inserted(UUID)
    /// 幂等键重复，跳过（携带命中的键，便于日志排查）。
    case skippedDuplicate(String)

    var wasInserted: Bool {
        if case .inserted = self { return true }
        return false
    }

    var entryID: UUID? {
        if case .inserted(let id) = self { return id }
        return nil
    }
}

/// 写入器。
@MainActor
final class LedgerWriter {

    /// 唯一被持有的写上下文。
    private let context: ModelContext

    /// 从容器创建（生产路径：App 启动时调用一次）。
    init(container: ModelContainer) {
        self.context = ModelContext(container)
    }

    /// 从既有上下文创建（测试 / 预览路径，允许注入已配置好的 context）。
    init(context: ModelContext) {
        self.context = context
    }

    /// 底层上下文。**仅供同模块的 Persistence/Services 使用**（如 `SweepCoordinator` 需要读订阅对象），
    /// Features 层不得持有（否则等于绕开单写入口）。
    var modelContext: ModelContext { context }

    // MARK: - 读

    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        try context.fetch(descriptor)
    }

    func count<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> Int {
        try context.fetchCount(descriptor)
    }

    func entry(id: UUID) throws -> LedgerEntry? {
        try context.fetch(QueryDescriptors.entry(id: id)).first
    }

    func subscription(id: UUID) throws -> Subscription? {
        try context.fetch(QueryDescriptors.subscription(id: id)).first
    }

    func category(id: UUID?) throws -> Category? {
        guard let id else { return nil }
        return try context.fetch(QueryDescriptors.category(id: id)).first
    }

    func account(id: UUID?) throws -> Account? {
        guard let id else { return nil }
        return try context.fetch(QueryDescriptors.account(id: id)).first
    }

    func todo(id: UUID) throws -> Todo? {
        try context.fetch(QueryDescriptors.todo(id: id)).first
    }

    // MARK: - 幂等（第 2 层）

    /// 幂等键是否已存在（**包含本 context 未提交的插入**）。
    ///
    /// 注意语义：R-SUB-7 要求"含软删除记录"唯一，所以这里**不过滤 `deletedAt`**——
    /// 一条被软删的订阅账目仍然占用它的周期键，这正是 B 分支必须硬删除的原因（风险 R8）。
    func isDuplicate(_ uniqueKey: String?) throws -> Bool {
        guard let key = uniqueKey, !key.isEmpty else { return false }
        return try count(QueryDescriptors.entry(withUniqueKey: key)) > 0
    }

    // MARK: - 写

    /// 插入一条账目。
    ///
    /// - Parameters:
    ///   - draft: 已通过业务校验的草稿。
    ///   - save: 是否立即提交。默认 `true`（一次插入 = 一个事务）；
    ///     结算扫描（`SweepCoordinator`）传 `false`，把"生成多笔 + 推进订阅日期"放进同一次 `save()`。
    /// - Returns: 插入结果。幂等键重复时返回 `.skippedDuplicate`，不抛错——重复不是错误，是正常的幂等命中。
    @discardableResult
    func insert(_ draft: EntryDraft, save: Bool = true) throws -> InsertOutcome {
        if let key = draft.uniqueKey, try isDuplicate(key) {
            return .skippedDuplicate(key)
        }

        let entry = draft.makeEntry()
        // 先 insert 再挂关系：关系必须在同一个 context 里解析成托管对象
        context.insert(entry)
        entry.category = try category(id: draft.categoryID)
        entry.account = try account(id: draft.accountID)
        entry.toAccount = try account(id: draft.toAccountID)

        if save {
            try context.save()
        }
        return .inserted(entry.id)
    }

    /// 在当前 context 内修改任意托管模型并提交（账户期初余额、分类改名、订阅推进日期等）。
    ///
    /// 与 `update(id:save:_:)` 的区别：账目按 id 定位（外部只持有 id），
    /// 其它对象由调用方自己持有模型引用，直接传对象更自然。
    ///
    /// - Parameters:
    ///   - model: 已托管的模型对象。
    ///   - save: 是否立即提交。
    ///   - mutate: 修改闭包。
    /// - Returns: 同一个对象（便于链式使用）。
    @discardableResult
    func update<T: PersistentModel>(_ model: T, save: Bool = true, _ mutate: (T) throws -> Void) throws -> T {
        try mutate(model)
        if save {
            try context.save()
        }
        return model
    }

    /// 插入任意非账目模型（订阅 / 待办 / 分类等）。
    ///
    /// 账目走 `insert(_ draft:)`（草稿 → 幂等 → 关系挂载），其余模型没有幂等键，
    /// 因此这里只做"放进同一个写 context"这一件事。集中在这里而不是让 Service 自己
    /// `context.insert`，是为了让「全项目只有一个写 context」这条铁律在代码里可验证。
    ///
    /// - Parameters:
    ///   - model: 待插入的模型（尚未托管）。
    ///   - save: 是否立即提交。批量写入（如结算扫描）传 `false`，与其他写入共用一次 `save()`。
    /// - Returns: 同一个对象。
    @discardableResult
    func insert<T: PersistentModel>(_ model: T, save: Bool = true) throws -> T {
        context.insert(model)
        if save {
            try context.save()
        }
        return model
    }

    /// 删除任意非账目模型（订阅删除 = 移除记录，历史账目靠 `sourceRefID` 悬空保留）。
    ///
    /// 账目的删除**不走这里**：软删 `softDelete` / 幂等重生的硬删 `hardDelete` 各有明确语义。
    ///
    /// - Parameters:
    ///   - model: 已托管的模型对象。
    ///   - save: 是否立即提交。
    @discardableResult
    func delete<T: PersistentModel>(_ model: T, save: Bool = true) throws -> Bool {
        context.delete(model)
        if save {
            try context.save()
        }
        return true
    }

    /// 在当前 context 内修改一条账目并提交。
    ///
    /// - Parameters:
    ///   - id: 账目 id。
    ///   - mutate: 修改闭包（只能改业务允许的字段，由调用方保证）。
    ///   - save: 是否立即提交。
    /// - Returns: 修改后的快照；账目不存在时返回 nil。
    @discardableResult
    func update(id: UUID, save: Bool = true, _ mutate: (LedgerEntry) throws -> Void) throws -> LedgerEntrySnapshot? {
        guard let entry = try entry(id: id) else { return nil }
        try mutate(entry)
        entry.updatedAt = Date()
        if save {
            try context.save()
        }
        return LedgerEntrySnapshot(entry: entry)
    }

    /// 软删除（R-EDIT-3）：只写删除标记与 `updatedAt`，其余字段一字不动，因此撤销天然完整。
    ///
    /// 内部走 `markDeleted(_:at:)`——软删标记的两个列（`deletedAt` / `deletedDay`）**只能**
    /// 从那一个入口写入（V1.1 风险 R1）。
    ///
    /// - Returns: 删除前的全字段快照，用于 3 秒撤销。
    @discardableResult
    func softDelete(id: UUID, at moment: Date = Date()) throws -> LedgerEntrySnapshot? {
        guard let entry = try entry(id: id) else { return nil }
        let snapshot = LedgerEntrySnapshot(entry: entry)
        try markDeleted(entry, at: moment)
        return snapshot
    }

    /// 撤销软删除：把快照的**全部字段**写回（不只是删除标记），并重新挂载关系。
    ///
    /// 恢复路径的三步走（顺序有意义）：
    /// ① `snapshot.apply(to:)` 写回业务标量（含 `confirmRaw`，恢复后不会悄悄变已确认）；
    /// ② 重新挂载 category / account / toAccount（关系要在这个 context 里解析）；
    /// ③ **删除标记走唯一入口**：快照未删除 → `unmarkDeleted`（`deletedAt = nil`、`deletedDay = 0`），
    ///    快照本身是已删除态 → `markDeleted`（两者同时写回）。
    ///    第 ③ 步必须是入口方法而不是"顺手写两行"，否则「最近删除」里的记录恢复后
    ///    `deletedDay` 会留着旧值，于是它会同时出现在账本和回收站里（风险 R1）。
    ///
    /// - Parameter snapshot: `softDelete` 返回的快照（或任何等价的账目快照）。
    /// - Returns: 是否成功恢复（账目已被硬删除时返回 false，不抛错）。
    @discardableResult
    func restore(_ snapshot: LedgerEntrySnapshot) throws -> Bool {
        guard let entry = try entry(id: snapshot.id) else { return false }
        snapshot.apply(to: entry)
        entry.category = try category(id: snapshot.categoryID)
        entry.account = try account(id: snapshot.accountID)
        entry.toAccount = try account(id: snapshot.toAccountID)
        if let mark = snapshot.deletion {
            Self.applyDeletion(to: entry, at: mark.at, day: mark.day)
        } else {
            Self.clearDeletion(on: entry)
        }
        entry.updatedAt = Date()
        try context.save()
        return true
    }

    // MARK: - 软删除标记的两个唯一入口（V1.1 风险 R1）

    /// 打上软删除标记的**唯一入口**。
    ///
    /// 软删除在存储层是**两列**：`deletedAt: Date?`（UI 展示"删除于何时"）与
    /// `deletedDay: Int32`（`yyyyMMdd` 日键，供 iOS 17 的 `#Predicate` 做整数比较——
    /// `Optional<Date>` 的非等值比较已知会崩，见 `TrashService` 注释）。
    ///
    /// 两列**必须同进同出**。任何一处只写一列，都会让记录同时出现在账本和「最近删除」里
    /// （账本按 `deletedAt == nil` 过滤、回收站按 `deletedDay > 0` 过滤）。所以这两个列
    /// 只允许经由本方法与 `unmarkDeleted(_:)` 写入，且访问级别刻意留成 internal 供
    /// 同模块的 `Diagnostics` 复用，跨模块（Features）拿不到 `ModelContext` 自然也拿不到这里。
    ///
    /// - Parameters:
    ///   - entry: 已托管的账目。
    ///   - moment: 删除时刻。同时决定 `deletedAt` 与 `deletedDay`，不接受"只给日键"的调用方式。
    func markDeleted(_ entry: LedgerEntry, at moment: Date) throws {
        Self.applyDeletion(to: entry, at: moment, day: DateOnly(moment).key)
        entry.updatedAt = moment
        try context.save()
    }

    /// 撤销软删除标记的**唯一入口**（把两列一起归零）。
    ///
    /// 注意：本方法只清标记，不写回业务字段。完整恢复（含字段与关系）走 `restore(_:)`，
    /// 那里也是调本方法，不在外部重复赋值。
    ///
    /// - Parameters:
    ///   - entry: 已托管的账目。
    ///   - moment: 恢复时刻（写入 `updatedAt`）。给默认值，于是 `unmarkDeleted(entry)` 这种
    ///     两参数调用照旧成立；「最近删除」的恢复会显式传，便于测试断言确定的时间。
    func unmarkDeleted(_ entry: LedgerEntry, at moment: Date = Date()) throws {
        Self.clearDeletion(on: entry)
        entry.updatedAt = moment
        try context.save()
    }

    /// 把两列一并写成"已删除"（**只允许本类内部调用**，不提交事务）。
    private static func applyDeletion(to entry: LedgerEntry, at moment: Date, day: Int32) {
        entry.deletedAt = moment
        // 容错：调用方若只给了日键（day > 0 而 moment 无关），也保证两列指向同一个自然日。
        entry.deletedDay = day > 0 ? day : DateOnly(moment).key
    }

    /// 把两列一并清成"未删除"（**只允许本类内部调用**，不提交事务）。
    private static func clearDeletion(on entry: LedgerEntry) {
        entry.deletedAt = nil
        entry.deletedDay = 0
    }

    /// 硬删除（**只允许订阅删账 B 分支使用**，见 R8：B 分支若软删，幂等键残留会让账目永不重生）。
    ///
    /// - Returns: 是否真的删掉了一条。
    @discardableResult
    func hardDelete(id: UUID) throws -> Bool {
        guard let entry = try entry(id: id) else { return false }
        context.delete(entry)
        try context.save()
        return true
    }

    /// 提交当前 context 的全部 pending changes（一次 = 一个 SQLite 事务）。
    func save() throws {
        try context.save()
    }

    /// 丢弃未提交的修改（异常路径用，避免半成品留在 context 里）。
    func rollback() {
        context.rollback()
    }
}
