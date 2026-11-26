//
//  ModelContainerFactory.swift
//  一账 / Core / Persistence
//
//  职责：全项目唯一的 ModelContainer 创建点。
//
//  一个 `bool` 开关决定是否接 iCloud 私有库：
//  - V1.0 / V1.1：`cloudKitEnabled = false` → `.none`（纯本地，无需 entitlement）
//  - 后续开同步：改成 true → `.automatic`（schema 不变，零迁移）
//
//  这就是"从第一天就是 CloudKit 形状"的收益：开同步只改一行常量。
//
//  V1.1 起本文件用 `SchemaV2` + `YiZhangMigrationPlan`（V1 → V2 一段轻量迁移）。
//  V1.0 时代这里的注释写着"V2 时容器创建代码零改动"，那句话是错的：
//  版本一变，`Schema(versionedSchema:)` 的入参和 `ModelContainer(for:migrationPlan:configurations:)`
//  都必须跟着改，否则旧库会打不开。此处已按事实改写，别再被旧注释误导。
//
//  iOS 17 的真实限制（架构 §3.4）：`#Index` 宏是 iOS 18 引入的，V1.0 无法声明自定义索引。
//  因此索引声明以注释形式预留在本文件末尾，抬到 iOS 18 只需取消注释，业务代码零改动。
//  在无索引的前提下，靠三条纪律把全表扫的代价压住：
//  ①所有查询用整数区间谓词；②`fetchLimit` + 分页；③统计限定单月/单年并尽早转 `LedgerLite`。
//

import Foundation
import SwiftData

/// ModelContainer 工厂。
enum ModelContainerFactory {

    /// iCloud 同步开关。V1.0 关闭；V1.1 改为 true 即可（需要 CloudKit entitlement）。
    static let cloudKitEnabled = false

    /// 创建容器。
    ///
    /// - Parameter inMemory: `true` 时使用内存库（单元测试 / 预览），不写磁盘。
    /// - Returns: 可用的 `ModelContainer`。
    ///
    /// - Note: 用的是**最新** schema（`SchemaV2`），并显式带上 `YiZhangMigrationPlan`。
    ///   两者必须成对出现：只换 schema 不带迁移计划，旧库会因"元数据版本对不上"直接打开失败；
    ///   带了迁移计划，SwiftData 才会按 `stages` 里的轻量迁移把旧库原地升级（补两列 + 建模板表）。
    ///   V1.0 的注释说"V2 时容器创建代码零改动"是**错的**——注释已按事实改写。
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudKitEnabled ? .automatic : .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: YiZhangMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// 预览 / 单元测试用的内存容器便利方法。
    ///
    /// 保持 `throws`（而不是 `try!`）：任何内存容器创建失败都应该让测试明确失败，
    /// 而不是在预览或测试里触发陷阱。
    static func inMemoryForPreview() throws -> ModelContainer {
        try make(inMemory: true)
    }
}

// MARK: - 索引声明（iOS 18 起可用，架构 §3.4）
//
// 抬到 iOS 18 后，把下面两行移入 `SchemaV2`（`#Index` 只能写在 `@Model` 类型或其 extension 上），
// 然后删掉这段注释即可，业务代码零改动：
//
//  extension LedgerEntry {
//      #Index<LedgerEntry>([\.occurredDay], [\.sourceCycleUniqueKey])
//  }
//  extension Subscription {
//      #Index<Subscription>([\.nextBillingDay], [\.statusRaw])
//  }
//
// 升级阈值（写进代码是为了避免"凭感觉优化"）：
//  - 真机首帧 > 80ms，或
//  - 单用户账目 > 20,000 条
// 任一命中时再引入索引或预聚合表。
