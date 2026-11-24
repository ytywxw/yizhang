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
//  3 秒撤销（R-EDIT-3）要求"撤销即完全恢复，含 sourceCycleKey 等所有字段"。
//  只存 entryID + deletedAt 也能恢复（软删只改两列），但一旦未来某条路径在软删后又改了别的字段，
//  仅靠 entryID 的恢复就会"恢复成被改过的样子"。全字段快照让这件事与实现细节无关。
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

// MARK: - 模型 → 快照

/// 账目的全字段值镜像。用于 3 秒撤销与自检修复，不参与持久化。
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
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let categoryID: UUID?
    let accountID: UUID?
    let toAccountID: UUID?

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
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        deletedAt = entry.deletedAt
        categoryID = entry.category?.id
        accountID = entry.account?.id
        toAccountID = entry.toAccount?.id
    }

    /// 显式全参初始化（测试构造人造快照用）。
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.categoryID = categoryID
        self.accountID = accountID
        self.toAccountID = toAccountID
    }

    var type: EntryType { EntryType(raw: typeRaw) ?? .expense }

    var source: EntrySource { EntrySource(raw: sourceRaw) ?? .manual }

    var occurredDate: DateOnly { DateOnly(key: occurredDay) }

    var amountMoney: Money { Money(cents: amount) }

    var isDeleted: Bool { deletedAt != nil }

    /// 把标量字段写回模型（关系由 `LedgerWriter.restore` 重新挂载）。
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
        entry.createdAt = createdAt
        entry.updatedAt = updatedAt
        entry.deletedAt = deletedAt
    }
}
