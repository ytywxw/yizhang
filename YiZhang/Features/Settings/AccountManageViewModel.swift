//
//  AccountManageViewModel.swift
//  一账 / Features / Settings
//
//  职责：账户管理的全部业务（T21）——列表 + 余额 + 新建 / 编辑 / 排序 / 删除降级归档。
//
//  ## 三个刻意的决定
//
//  ① **余额永远算，不存**（R-ACC-1）：本类每次 `load()` 从 `AccountBalanceCalculator`
//     重算一遍。存余额会引入"新增/编辑/软删/撤销/订阅扫描/恢复"六条同步路径，
//     漏一条用户就会看到"余额和流水对不上"，而且错误是累积的。
//  ② **有账目时删除降级为归档**（R-ACC-2）：硬删账户会让历史账目失去账户引用
//     （`deleteRule: .nullify`），用户看到的是"我这笔钱从哪个账户出的？——空白"。
//     所以删除前先 `deletePreview`，让 UI 把"将改为归档"说清楚，再执行。
//  ③ **归档只影响选择器，不影响历史**：`selectableRows` 是记账页唯一该看的列表。
//
//  写入一律走 `environment.writer`（同一个 context、同一次 save），
//  不新建 ModelContext——否则账户改名与账目引用会落在两个事务里。
//

import Foundation
import Observation
import SwiftData

/// 账户管理 ViewModel。
@Observable
@MainActor
final class AccountManageViewModel {

    // MARK: - 行

    /// 列表行（余额已算好，视图不做算术）。
    struct Row: Identifiable, Hashable {

        let id: UUID
        let name: String
        let kindRaw: String
        let initialBalanceCents: Int64
        /// 期初 − Σ支出 + Σ收入 − Σ转出 + Σ转入（R-ACC-1）。
        let balanceCents: Int64
        /// 引用该账户的**未删除**账目条数（转账两侧都算）。
        let entryCount: Int
        let isArchived: Bool
        let sortOrder: Int

        var kind: AccountKind { AccountKind(raw: kindRaw) ?? .cash }

        var balance: Money { Money(cents: balanceCents) }

        var initialBalance: Money { Money(cents: initialBalanceCents) }

        var symbolName: String { kind.symbolName }

        /// 信用卡欠款表现为负余额，UI 不该把它当成错误（R-ACC-3）。
        var isNegativeBalanceExpected: Bool { kind == .credit }
    }

    // MARK: - 删除意图

    /// 删除的两种结果。
    enum DeleteOutcome: Hashable, Sendable {
        /// 真的删了（没有账目引用）。
        case deleted
        /// 降级归档（有账目引用，`count` 是引用条数）。
        case archived(entryCount: Int)
    }

    /// 删除前的预览：UI 据此决定弹窗文案。
    struct DeletePreview: Hashable, Sendable {
        let id: UUID
        let name: String
        let entryCount: Int

        /// 有账目 → 只能归档。
        var willArchive: Bool { entryCount > 0 }

        /// 弹窗正文（写成一句话，避免各处自己拼）。
        var message: String {
            willArchive
                ? "该账户下有 \(entryCount) 笔账目，将改为归档而不是删除。归档后不再出现在记账选择器里，历史账目保留。"
                : "该账户没有任何账目，删除后无法恢复。"
        }
    }

    // MARK: - 状态

    private(set) var rows: [Row] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    @ObservationIgnored
    private var environment: AppEnvironment?

    // MARK: - 加载

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
        load()
    }

    /// 重新读账户 + 重算余额。
    func load() {
        guard let environment else { return }
        do {
            rows = try makeRows(environment)
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = "账户读取失败：\(error.localizedDescription)。退出这一页再进来可以重试。"
        }
        isLoaded = true
    }

    /// 记账页/编辑器唯一该用的账户列表（不含归档）。
    var selectableRows: [Row] {
        rows.filter { !$0.isArchived }
    }

    var archivedRows: [Row] {
        rows.filter(\.isArchived)
    }

    // MARK: - 新建 / 编辑

    /// 新建账户。
    ///
    /// - Returns: 新账户 id。
    @discardableResult
    func create(
        name: String,
        kind: AccountKind,
        initialBalanceCents: Int64 = 0
    ) throws -> UUID {
        guard let environment else { throw AccountManageError.notReady }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountManageError.emptyName }

        let account = Account()
        account.id = UUID()
        account.name = trimmed
        account.kind = kind
        account.initialBalance = initialBalanceCents
        account.isArchived = false
        account.sortOrder = (rows.map(\.sortOrder).max() ?? -1) + 1
        let now = Date()
        account.createdAt = now
        account.updatedAt = now

        do {
            try environment.writer.insert(account)
        } catch {
            environment.writer.rollback()
            throw AccountManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
        return account.id
    }

    /// 编辑账户（名称 / 类型 / 期初余额）。**余额不可这里改**（R-ACC-1）。
    func update(
        id: UUID,
        name: String,
        kind: AccountKind,
        initialBalanceCents: Int64
    ) throws {
        guard let environment else { throw AccountManageError.notReady }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountManageError.emptyName }
        guard let account = try environment.writer.account(id: id) else {
            throw AccountManageError.notFound
        }

        do {
            try environment.writer.update(account) { model in
                model.name = trimmed
                model.kind = kind
                model.initialBalance = initialBalanceCents
                model.updatedAt = Date()
            }
        } catch {
            environment.writer.rollback()
            throw AccountManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
    }

    // MARK: - 归档 / 取消归档

    func archive(id: UUID) throws {
        try setArchived(id: id, archived: true)
    }

    func unarchive(id: UUID) throws {
        try setArchived(id: id, archived: false)
    }

    private func setArchived(id: UUID, archived: Bool) throws {
        guard let environment else { throw AccountManageError.notReady }
        guard let account = try environment.writer.account(id: id) else {
            throw AccountManageError.notFound
        }
        do {
            try environment.writer.update(account) { model in
                model.isArchived = archived
                model.updatedAt = Date()
            }
        } catch {
            environment.writer.rollback()
            throw AccountManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
    }

    // MARK: - 删除

    /// 删除前预览：告诉 UI 这是"真删"还是"降级归档"。
    ///
    /// 计数必须与 `delete(id:)` **同口径、同一个函数**（`liveEntryCount`，含转入到
    /// 该账户的转账）。用行里的 `entryCount` 会出两种错：
    /// ① 它只在 `attach` / 自身写操作后刷新，页面存活期间的外部写入看不到（P1）；
    /// ② 它不统计转入的转账，于是"只有转账转入"的账户弹窗写着「没有任何账目」，
    ///    点下去却被归档 —— 说的是 A、做的是 B，用户会以为自己删掉了账户。
    func deletePreview(for id: UUID) -> DeletePreview? {
        guard let environment, let row = rows.first(where: { $0.id == id }) else { return nil }
        let count = (try? liveEntryCount(accountID: id, in: environment)) ?? row.entryCount
        return DeletePreview(id: row.id, name: row.name, entryCount: count)
    }

    /// 该账户下**现存**的账目条数（含转入到它的转账，与列表里显示的笔数同口径）。
    ///
    /// ## 为什么必须现数，不能用 `rows` 里的 `entryCount`
    ///
    /// `rows` 只在 `attach()` 和自身写操作后刷新。**页面存活期间的外部写入**——
    /// 最真实的一条路径是：用户停在账户页 → App 进后台 → 回前台触发
    /// `SweepCoordinator.sweep()` 落下一批订阅账目 —— 这时 `rows` 里还是旧值 0。
    /// 用旧值判断分支，就会把"有 3 笔账目的账户"真删掉，账目随之失去账户
    /// （关系是 `.nullify`，账目还在，但详情里显示「账户已删除」）。
    ///
    /// ## 为什么是全表扫而不是关系谓词
    ///
    /// `$0.account?.id == id` 这类 **Optional 关系谓词**在本项目已被登记为
    /// iOS 17 的崩溃面（见 `QueryDescriptors` 里 R10 的说明），所以这里沿用
    /// `makeRows` 的同一条路：拉未删除的账目（纯标量谓词），内存里按账户分桶。
    /// 1 万条约 10ms，只发生在"点删除"这一下，不在渲染路径上。
    private func liveEntryCount(accountID: UUID, in environment: AppEnvironment) throws -> Int {
        let liveEntries = try environment.writer.fetch(
            FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.deletedAt == nil })
        )
        var count = 0
        for entry in liveEntries {
            let sourceID = entry.account?.id
            if sourceID == accountID { count += 1 }
            // 转入到该账户的转账同样引用它，删账户一样会让这笔账失去目标
            if entry.toAccount?.id == accountID, sourceID != accountID { count += 1 }
        }
        return count
    }

    /// 执行删除：有账目 → 归档；无账目 → 真删。
    ///
    /// **分支判据来自现数**（`liveEntryCount`），不来自 `deletePreview`——
    /// 后者读的是 UI 快照，可能已经过期（见 P1 回归测试）。
    @discardableResult
    func delete(id: UUID) throws -> DeleteOutcome {
        guard let environment else { throw AccountManageError.notReady }

        let liveCount: Int
        do {
            liveCount = try liveEntryCount(accountID: id, in: environment)
        } catch {
            throw AccountManageError.saveFailed(error.localizedDescription)
        }

        do {
            if liveCount > 0 {
                guard let account = try environment.writer.account(id: id) else {
                    throw AccountManageError.notFound
                }
                try environment.writer.update(account) { model in
                    model.isArchived = true
                    model.updatedAt = Date()
                }
                finishWrite()
                return .archived(entryCount: liveCount)
            }

            guard let account = try environment.writer.account(id: id) else {
                throw AccountManageError.notFound
            }
            try environment.writer.delete(account)
        } catch let error as AccountManageError {
            throw error
        } catch {
            environment.writer.rollback()
            throw AccountManageError.saveFailed(error.localizedDescription)
        }

        finishWrite()
        return .deleted
    }

    // MARK: - 排序

    /// 把某个账户移到新位置（拖拽排序的唯一入口）。
    ///
    /// 只改 `sortOrder`，一次 save 提交：拖一次产生 N 条改动但只落一个事务，
    /// 中途被杀不会留下"两个账户同序号"的排序。
    func move(id: UUID, toIndex destination: Int) throws {
        guard let environment else { throw AccountManageError.notReady }
        guard let currentIndex = rows.firstIndex(where: { $0.id == id }) else {
            throw AccountManageError.notFound
        }
        var reordered = rows
        let moved = reordered.remove(at: currentIndex)
        let target = min(max(destination, 0), reordered.count)
        reordered.insert(moved, at: target)

        do {
            for (index, row) in reordered.enumerated() where row.sortOrder != index {
                guard let account = try environment.writer.account(id: row.id) else { continue }
                account.sortOrder = index
                account.updatedAt = Date()
            }
            try environment.writer.save()
        } catch {
            environment.writer.rollback()
            throw AccountManageError.saveFailed(error.localizedDescription)
        }
        finishWrite()
    }

    // MARK: - 错误

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 私有收尾

    /// 写入成功后的收尾：**先广播，再刷自己**。
    ///
    /// 为什么必须广播（R2）：账户名会被 `EntryRowModel.accountName` 以字符串快照
    /// 拷进账本列表的每一行，只有 `dataVersion` 变了首页才重算。本类直接拿
    /// `writer` 改数据、绕过了 4 个 Service 的 `onDidCommit`，不补这一下，
    /// 「微信」改名成「微信零钱」后返回账本，列表里还写着「微信」，要等下次记账
    /// 或切月才更新——用户会以为改名没生效。
    ///
    /// 反过来**不给 `writer` 加全局回调**：那会让 Service 的写入被广播两次
    /// （Service 的 `onDidCommit` 一次 + writer 一次），`.task(id:)` 白跑一轮。
    ///
    /// 注意 `load()` 自己**不**广播——它是纯读取，会 `.task(id: dataVersion)`
    /// 自激成死循环（有专门用例守着这条）。
    private func finishWrite() {
        environment?.bumpDataVersion()
        load()
    }

    // MARK: - 组装行

    private func makeRows(_ environment: AppEnvironment) throws -> [Row] {
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let entries = try environment.writer.fetch(QueryDescriptors.allEntries())

        // 一次扫描把所有账户的流水分好桶：N 个账户 × M 条账目 → O(N+M)，
        // 而不是每个账户各扫一遍全表（N×M）。
        var movements: [UUID: [AccountBalanceCalculator.Movement]] = [:]
        var counts: [UUID: Int] = [:]

        for entry in entries {
            guard entry.deletedAt == nil else { continue }
            let movement = AccountBalanceCalculator.Movement(
                amountCents: entry.amount,
                typeRaw: entry.typeRaw,
                accountID: entry.account?.id,
                toAccountID: entry.toAccount?.id
            )
            if let sourceID = entry.account?.id {
                movements[sourceID, default: []].append(movement)
                counts[sourceID, default: 0] += 1
            }
            if let targetID = entry.toAccount?.id, targetID != entry.account?.id {
                movements[targetID, default: []].append(movement)
                counts[targetID, default: 0] += 1
            }
        }

        return accounts.map { account in
            let snapshot = AccountBalanceCalculator.AccountSnapshot(
                id: account.id,
                initialBalanceCents: account.initialBalance,
                kindRaw: account.kindRaw
            )
            let balance = AccountBalanceCalculator.balance(
                account: snapshot,
                movements: movements[account.id] ?? []
            )
            return Row(
                id: account.id,
                name: account.displayName,
                kindRaw: account.kindRaw,
                initialBalanceCents: account.initialBalance,
                balanceCents: balance.cents,
                entryCount: counts[account.id] ?? 0,
                isArchived: account.isArchived,
                sortOrder: account.sortOrder
            )
        }
        .sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name < rhs.name
        }
    }
}

// MARK: - 错误

/// 账户操作错误（都是用户能看懂的句子）。
enum AccountManageError: LocalizedError, Hashable {
    case notReady
    case emptyName
    case notFound
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "数据还没准备好，请稍后再试"
        case .emptyName:
            return "账户名称不能为空"
        case .notFound:
            return "找不到这个账户，可能已被删除"
        case .saveFailed(let reason):
            return "保存失败：\(reason)"
        }
    }
}
