//
//  DeletionMark.swift
//  一账 / Core / Domain
//
//  职责：「一条记录被软删除」这件事的唯一值表示（V1.1 / 风险 R1）。
//
//  ## 为什么需要一个类型
//
//  V1.1 的软删除在存储层是**两列**：
//  - `deletedAt: Date?`  —— 删除时刻，用于「最近删除」内的二次排序与"删除于 3 分钟前"这类文案；
//  - `deletedDay: Int32` —— `yyyyMMdd` 日键，用于 iOS 17 的 `#Predicate`（见下）与按天分组。
//
//  这两列是**同一个事实**的两种表示。若把它们做成两个可独立赋值的存储属性，
//  就允许出现"时刻有值、日键为 0"的中间态——这种记录在「最近删除」里既看不到、
//  也永不被 `purgeExpired` 清理，属于最容易犯又最难发现的错。
//  合并成一个值类型之后，"两者不同步"在类型层面就表达不出来。
//
//  ## 为什么不用 `Optional<Date>` 做谓词
//
//  iOS 17 的 `#Predicate` 对 `Optional<Date>` 的非等值比较（`!= nil` / `>` / `<`）
//  有已知崩溃面，因此回收站的查询一律用整数谓词 `deletedDay > 0`、`deletedDay < X`。
//  这也是 `deletedDay` 这一列存在的唯一理由——它不是冗余，是谓词可用性的前提。
//
//  本文件是纯 Swift（只依赖 `DateOnly`）：不 import SwiftData / SwiftUI，
//  于是 Models 层的快照与 Domain 层的 `LedgerLite` 可以共用同一个表示。
//

import Foundation

/// 一条记录的删除标记。
///
/// 构造后两个字段都不可变：`at` 与 `day` 永远指向同一个自然日。
struct DeletionMark: Hashable, Sendable {

    /// 删除时刻（精确时间，「最近删除」列表内的二次排序用它）。
    let at: Date

    /// 删除日 `yyyyMMdd`（`deletedDay` 列的值，恒 > 0）。
    let day: Int32

    /// 从时刻构造。
    ///
    /// - Parameters:
    ///   - at: 删除时刻。
    ///   - day: 已算好的日键。`nil` 或 `<= 0` 时由 `at` 反算
    ///     （`DateOnly` 是全项目唯一的「时刻 → 自然日」换算点，A2 铁律）。
    init(at: Date, day: Int32? = nil) {
        self.at = at
        let resolved = day ?? 0
        // 双保险：即便调用方传了 0（"未删除"的哨兵值），也在这里按 at 补出一个合法日键，
        // 绝不产出 day == 0 的"已删除但看不见"的记录。
        self.day = resolved > 0 ? resolved : DateOnly(at).key
    }

    /// 日键对应的自然日（分组、过期判定用）。
    var date: DateOnly { DateOnly(key: day) }
}
