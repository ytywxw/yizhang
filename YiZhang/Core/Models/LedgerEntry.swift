//
//  LedgerEntry.swift
//  一账 / Core / Models
//
//  职责：账目模型（PRD 3.2.1 / 架构 §3.1）。纯数据 + 便捷计算属性（不参与持久化）。
//
//  CloudKit 形状的硬约束（架构 §3.6，V1.1 开同步时只改一个常量，schema 一字节不变）：
//  1. 每个标量都有字面量默认值；`Date` 默认 `Date(timeIntervalSince1970: 0)` 而非 `.now`
//     （迁移确定性：绝不能让默认值依赖"编译/运行那一刻"）；
//  2. 关系全部可选（`Model? = nil` / `[Model]? = []`）；
//  3. 每个 to-many 显式声明 `inverse:`；
//  4. 全项目 0 处 `.unique`、0 处 `.deny`、0 处 `.cascade`
//     （`@Attribute(.unique)` 的 upsert 语义会静默改写历史账目，且开同步时必须摘掉，无法轻量迁移）；
//  5. 零 `#Index`（iOS 18 才有，声明以注释形式预留在 `ModelContainerFactory`）；
//  6. 所有"日"字段用 `Int32 yyyyMMdd`，`0` 作哨兵，模型里没有一个 `Int32?`（谓词全是整数比较）；
//  7. 枚举存 `xxxRaw: String`，转换由本文件的便捷计算属性完成。
//
//  写入纪律（A3）：`LedgerEntry` 的唯一写入者是 `LedgerWriter`。T06 会把便捷 init 收窄为
//  `fileprivate`，届时 Features 层在语法上就无法 new 一个账目。
//

import Foundation
import SwiftData

/// 一笔账目。
@Model
final class LedgerEntry {

    // MARK: - 标量字段（全部带默认值）

    /// 主键。
    var id: UUID = UUID()

    /// `EntryType` 的 raw 值：expense / income / transfer。
    var typeRaw: String = EntryType.expense.raw

    /// 金额（分）。业务规则：> 0。A1：永远不用浮点。
    var amount: Int64 = 0

    /// 账目发生的自然日，`yyyyMMdd`（权威字段）。A2：整数无时区，永不漂移。
    var occurredDay: Int32 = 0

    /// 备注（≤ 100 字，业务层校验）。
    var note: String = ""

    /// P1 预留标签，V1.0 不暴露 UI。
    var tags: [String]? = nil

    /// `EntrySource` 的 raw 值：manual / todo / subscription。
    var sourceRaw: String = EntrySource.manual.raw

    /// 源对象 id（待办 / 订阅）。弱引用语义：源对象删除后账目仍保留，详情页显示"来源已删除"。
    var sourceRefID: UUID? = nil

    /// 订阅周期键（仅订阅来源）。month/quarter/year → `yyyy-MM`；day/week → `d-yyyyMMdd`。
    var sourceCycleKey: String? = nil

    /// 幂等键 `"<sourceRefID>|<cycleKey>"`。**普通 String?**，不是唯一约束。
    /// 幂等由"单写入口 + 先查后插 + 启动自检"三层保证（架构 §3.3）。
    var sourceCycleUniqueKey: String? = nil

    /// 创建时间（审计字段）。
    var createdAt: Date = Date(timeIntervalSince1970: 0)

    /// 最后修改时间（审计字段）。
    var updatedAt: Date = Date(timeIntervalSince1970: 0)

    /// 软删除时间（R-EDIT-3）。非 nil 表示已删除；撤销即把它置回 nil。
    var deletedAt: Date? = nil

    // MARK: - 关系（全部可选 + 反向关系在父端声明）

    /// 分类。转账类型使用内置「转账」占位分类。
    var category: Category? = nil

    /// 付款账户（转账时为转出账户）。
    var account: Account? = nil

    /// 转入账户，仅 `transfer` 使用，且 `toAccount != account`。
    var toAccount: Account? = nil

    /// 由本账目回写关联的待办（`Todo.linkedEntry` 的反向关系）。
    ///
    /// 架构 §3.1 未列出这一侧，但 CloudKit 要求每个关系都有反向关系，
    /// 显式声明比让 SwiftData 隐式生成更可控，因此这里补上（不新增业务含义）。
    @Relationship(deleteRule: .nullify, inverse: \Todo.linkedEntry)
    var linkedTodos: [Todo]? = []

    // MARK: - 初始化

    /// 空初始化。
    ///
    /// **刻意声明为 `fileprivate`**（架构 §5.3 / A3）：除本文件外，全项目没有任何代码能凭空
    /// `LedgerEntry()` 造一个账目，唯一入口是 `init(draft:)` → `LedgerWriter.insert`。
    ///
    /// 诚实说明：Swift 的 `fileprivate` 是文件级隔离，无法跨文件表达"仅 Persistence 可见"。
    /// 因此这道门挡的是"随手 new 一条账目"的写法；真正的约束是
    /// 「Service 校验 → Writer 落库」这条唯一通路 + code review。
    fileprivate init() {}

    /// 从草稿构造。所有字段一次性写入，避免"构造一半"的对象被 `insert` 进库。
    ///
    /// 关系（category / account / toAccount）不在这里挂载——需要 `ModelContext` 才能解析，
    /// 由 `LedgerWriter.insert` 负责，见 `LedgerEntry+Draft.swift` 的说明。
    ///
    /// - Parameter draft: 已通过 `LedgerService` 校验的账目草稿。
    convenience init(draft: EntryDraft) {
        self.init()
        let now = Date()
        typeRaw = draft.typeRaw
        amount = draft.amount
        occurredDay = draft.occurredDay
        note = draft.note
        sourceRaw = draft.sourceRaw
        sourceRefID = draft.sourceRefID
        sourceCycleKey = draft.sourceCycleKey
        sourceCycleUniqueKey = draft.sourceCycleUniqueKey
        createdAt = now
        updatedAt = now
        deletedAt = nil
    }

    // MARK: - 便捷计算属性（不参与持久化）

    /// 账目类型。
    var type: EntryType {
        get { EntryType(raw: typeRaw) ?? .expense }
        set { typeRaw = newValue.raw }
    }

    /// 账目来源。
    var source: EntrySource {
        get { EntrySource(raw: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.raw }
    }

    /// 发生自然日。
    var occurredDate: DateOnly {
        get { DateOnly(key: occurredDay) }
        set { occurredDay = newValue.key }
    }

    /// 发生时刻（仅供 `DatePicker` 绑定与展示）。
    var occurredAt: Date {
        get { occurredDate.date }
        set { occurredDate = DateOnly(newValue) }
    }

    /// 金额值类型。
    var amountMoney: Money {
        get { Money(cents: amount) }
        set { amount = newValue.cents }
    }

    /// 是否已软删除。
    var isDeleted: Bool { deletedAt != nil }

    /// 是否计入统计（未软删）。
    var isActive: Bool { deletedAt == nil }

    /// 所属月份键 `yyyyMM`。
    var monthKey: Int32 { occurredDate.monthKey }

    /// 是否为转账。
    var isTransfer: Bool { type == .transfer }

    /// 是否带来源徽章（手动记账不需要）。
    var needsSourceBadge: Bool { source.needsBadge }

    /// 转账的两个账户是否都齐备（谓词外的 UI 校验用）。
    var isTransferComplete: Bool {
        guard isTransfer else { return true }
        guard let from = account, let to = toAccount else { return false }
        return from.id != to.id
    }
}
