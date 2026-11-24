//
//  SchemaV1.swift
//  一账 / Core / Persistence
//
//  职责：显式声明 schema 版本与迁移计划（架构 §3.6）。
//
//  为什么 V1.0 就要有 `VersionedSchema`：
//  V1.1 打开 iCloud 同步时 schema 一个字节都不变——这就是 A4「数据模型从第一天就是 CloudKit 形状」
//  的兑现方式：只需把 `ModelContainerFactory.cloudKitEnabled` 改成 true，不需要新增迁移 stage。
//  反过来说，若首版用了 `.unique` / 缺默认值 / 必选关系，到时就要做非轻量迁移，有丢数据风险，
//  而摘除唯一约束不是轻量迁移。
//
//  迁移计划先建成空壳（`stages = []`）：V2 时只需在 `stages` 里追加 `MigrationStage`，
//  容器创建代码零改动。
//

import Foundation
import SwiftData

/// schema 第 1 版：六个模型。
enum SchemaV1: VersionedSchema {

    /// 版本号 1.0.0。
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// 本版包含的全部模型。
    ///
    /// 顺序不重要，但保持"账目 → 账户 → 分类 → 订阅 → 待办 → 设置"的稳定顺序，
    /// 便于人工核对与后续 diff。
    static var models: [any PersistentModel.Type] {
        [
            LedgerEntry.self,
            Account.self,
            Category.self,
            Subscription.self,
            Todo.self,
            AppSettings.self
        ]
    }
}

/// 迁移计划。V1.0 只有一版，因此没有任何 stage。
enum YiZhangMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}
