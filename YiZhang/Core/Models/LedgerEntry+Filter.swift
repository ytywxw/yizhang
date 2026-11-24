//
//  LedgerEntry+Filter.swift
//  一账 / Core / Models
//
//  职责：把 `LedgerEntry` 与首页行模型接到 `EntryFilterTarget` 协议上（T09）。
//
//  为什么单独一个小文件而不是塞进 `EntryFilter.swift`：
//  `EntryFilter.swift` 属于 Domain 层，**不允许 import SwiftData**（架构 §2 目录红线）；
//  而让 `LedgerEntry` 满足协议必须在这个模型附近做。分层靠文件位置表达，比靠注释表达硬。
//
//  两个 `computed` 属性的语义：
//  - `categoryID`：关系 → id 的一次取值（转账为 nil）；
//  - `accountIDs`：**转账两侧都算**，所以是集合不是单个值。
//

import Foundation

// MARK: - LedgerEntry

extension LedgerEntry: EntryFilterTarget {

    /// 分类 id（转账无分类）。
    var categoryID: UUID? { category?.id }

    /// 涉及账户（转出 + 转入）。
    var accountIDs: Set<UUID> {
        var ids = Set<UUID>()
        if let accountID = account?.id { ids.insert(accountID) }
        if let toAccountID = toAccount?.id { ids.insert(toAccountID) }
        return ids
    }
}

// MARK: - 首页行模型

extension EntryRowModel: EntryFilterTarget {

    /// 发生日键（`day` 是 `DateOnly`，这里是它落库用的整数）。
    var occurredDay: Int32 { day.key }

    /// 涉及账户（转出 + 转入）。
    var accountIDs: Set<UUID> {
        var ids = Set<UUID>()
        if let accountID { ids.insert(accountID) }
        if let toAccountID { ids.insert(toAccountID) }
        return ids
    }
}
