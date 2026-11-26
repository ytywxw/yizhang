//
//  LedgerEntry+Draft.swift
//  一账 / Core / Models
//
//  职责：账目的"构造与镜像"——草稿 → 模型（构造），模型 → 快照（镜像）。
//
//  为什么单独一个文件（架构 §5.3 / A3）：
//  `LedgerEntry.init()` 被收窄为 `fileprivate`，于是"造一条账目"这件事只剩两个合法入口：
//  ① 本文件的 `init(draft:)`（声明在 LedgerEntry.swift 内，才能调用 fileprivate init）；
//  ② `LedgerWriter.insert`（唯一调用 ① 的地方）。
//  Features 层既拿不到 `init()`，也没有理由去拼 `EntryDraft`——它必须经过 `LedgerService`
//  校验金额与分类。这条链路是"账目只有一个写入者"的落地方式。
//
//  快照（`LedgerEntrySnapshot`）的存在理由：
//  3 秒撤销（R-EDIT-3）与「最近删除」恢复（V1.1）都要求"恢复即完全恢复，含 sourceCycleKey
//  等所有字段"。只存 entryID 也能恢复（软删只改两列），但一旦未来某条路径在软删后又改了别的
//  字段，仅靠 entryID 的恢复就会"恢复成被改过的样子"。全字段快照让这件事与实现细节无关。
//
//  ⚠️ V1.1 的关键改动：软删字段从 1 个变成 2 个（`deletedAt` + `deletedDay`），
//  两者**必须同进同出**（风险 R1）。为了不让"漏写其中一个"在语法上就可能发生，
//  快照内部把它们合并成一个值类型 `DeletionMark`，对外仍暴露 `deletedAt` / `deletedDay`
//  两个只读属性（既有调用方零改动）。
//

import Foundation

// MARK: - 草稿 → 模型

extension EntryDraft {

    /// 造一个尚未挂载关系的账目对象。
    ///
    /// **不要直接调用**：唯一调用点是 `LedgerWriter.insert(_:save:)`，
    /// 它会紧接着把 category / account / toAccount 挂上再 `save()`。
    /// 直接调用会得到一个关系为 nil 的账目（等于制造孤儿数据）。
    func makeEntry() -> LedgerEntry {
        LedgerEntry(draft: self)
    }

    /// 金额是否满足"账目必须有正金额"（R-IN-1 / 记账侧唯一硬性金额规则）。
    var hasPositiveAmount: Bool { amount > 0 }

    /// 是否是转账草稿。
    var isTransfer: Bool { type == .transfer }
}

// MARK: - 删除标记（deletedAt + deletedDay 的合并表示）

// `DeletionMark` 定义在 `Core/Domain/DeletionMark.swift`：
// 它是纯值语义的领域概念，快照（本文件）与 `LedgerLite`（Domain）共用同一份实现，
// 因此放在最底层，避免 Models ↔ Domain 的双向依赖。

// MARK: - 模型 → 快照

/// 账目的全字段值镜像。用于 3 秒撤销、「最近删除」恢复与自检修复，不参与持久化。
struct LedgerEntrySnapshot: Hashable, Sendable {

    let id: UUID
    let typeRaw: String
    let amount: Int64
    let occurredDay: Int32
    let note: String
    let tags: [String]?
    let sourceRaw: String
    let sourceRefID: UUID?
    let sourceCycleKey: String?
    let sourceCycleUniqueKey: String?
    /// `EntryConfirmation` 的 raw 值（V1.1）。**恢复时必须原样写回**：
    /// 一笔被否定的 pending 账目恢复后仍是 pending，不能悄悄变成已确认（PRD 6.3-5）。
    let confirmRaw: String
    let createdAt: Date
    let updatedAt: Date
    /// 删除标记；`nil` = 未删除。`deletedAt` / `deletedDay` 由它派生，二者不可能脱节。
    let deletion: DeletionMark?
    let categoryID: UUID?
    let accountID: UUID?
    let toAccountID: UUID?

    /// 删除时刻（`nil` = 未删除）。
    var deletedAt: Date? { deletion?.at }

    /// 删除日 `yyyyMMdd`（`0` = 未删除）。
    var deletedDay: Int32 { deletion?.day ?? 0 }

    /// 从模型当前状态拍一张快照。
    init(entry: LedgerEntry) {
        id = entry.id
        typeRaw = entry.typeRaw
        amount = entry.amount
        occurredDay = entry.occurredDay
        note = entry.note
        tags = entry.tags
        sourceRaw = entry.sourceRaw
        sourceRefID = entry.sourceRefID
        sourceCycleKey = entry.sourceCycleKey
        sourceCycleUniqueKey = entry.sourceCycleUniqueKey
        confirmRaw = entry.confirmRaw
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        deletion = entry.deletedAt.map { DeletionMark(at: $0, day: entry.deletedDay) }
        categoryID = entry.category?.id
        accountID = entry.account?.id
        toAccountID = entry.toAccount?.id
    }

    /// 显式全参初始化（测试构造人造快照用）。
    ///
    /// `deletedAt` / `deletedDay` 保持两个参数（既有调用方零改动），
    /// 但内部仍然收敛成一个 `DeletionMark`：`deletedAt` 为 nil 时 `deletedDay` 恒为 0。
    init(
        id: UUID,
        typeRaw: String = EntryType.expense.raw,
        amount: Int64 = 0,
        occurredDay: Int32 = 0,
        note: String = "",
        tags: [String]? = nil,
        sourceRaw: String = EntrySource.manual.raw,
        sourceRefID: UUID? = nil,
        sourceCycleKey: String? = nil,
        sourceCycleUniqueKey: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        deletedAt: Date? = nil,
        deletedDay: Int32 = 0,
        confirmRaw: String = EntryConfirmation.confirmed.raw,
        categoryID: UUID? = nil,
        accountID: UUID? = nil,
        toAccountID: UUID? = nil
    ) {
        self.id = id
        self.typeRaw = typeRaw
        self.amount = amount
        self.occurredDay = occurredDay
        self.note = note
        self.tags = tags
        self.sourceRaw = sourceRaw
        self.sourceRefID = sourceRefID
        self.sourceCycleKey = sourceCycleKey
        self.sourceCycleUniqueKey = sourceCycleUniqueKey
        self.confirmRaw = confirmRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        deletion = deletedAt.map { DeletionMark(at: $0, day: deletedDay) }
        self.categoryID = categoryID
        self.accountID = accountID
        self.toAccountID = toAccountID
    }

    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

    var source: EntrySource { EntrySource(raw: sourceRaw) ?? .manual }

    var confirmedState: EntryConfirmation { EntryConfirmation(raw: confirmRaw) ?? .confirmed }

    var isPending: Bool { confirmRaw == EntryConfirmation.pending.raw }

    var occurredDate: DateOnly { DateOnly(key: occurredDay) }

    var amountMoney: Money { Money(cents: amount) }

    var isDeleted: Bool { deletedAt != nil }

    /// 把**标量**字段写回模型（关系由 `LedgerWriter.restore` 重新挂载）。
    ///
    /// ⚠️ 刻意**不写** `deletedAt` / `deletedDay`：软删状态只有两个合法入口
    /// （`LedgerWriter.markDeleted(_:at:)` / `unmarkDeleted(_:)`），
    /// 恢复路径由 `LedgerWriter.restore(_:)` 在调用本方法后立刻走 `unmarkDeleted`
    /// （若快照本身是"已删除态"，则走 `markDeleted`）。这样"恢复后 `deletedDay` 归零"
    /// 是由唯一入口保证的，而不是靠这段代码记得多写一行（风险 R1）。
    ///
    /// - Parameter entry: 同一个 id 的模型对象。
    func apply(to entry: LedgerEntry) {
        entry.typeRaw = typeRaw
        entry.amount = amount
        entry.occurredDay = occurredDay
        entry.note = note
        entry.tags = tags
        entry.sourceRaw = sourceRaw
        entry.sourceRefID = sourceRefID
        entry.sourceCycleKey = sourceCycleKey
        entry.sourceCycleUniqueKey = sourceCycleUniqueKey
        entry.confirmRaw = confirmRaw
        entry.createdAt = createdAt
        entry.updatedAt = updatedAt
    }
}
