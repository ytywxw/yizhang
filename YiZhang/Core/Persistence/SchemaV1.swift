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
//  ## V1.1 的落法（`SchemaV2`）
//
//  V1.1 只做加法：`LedgerEntry` 加两个带字面量默认值的标量（`confirmRaw` / `deletedDay`）、
//  加一个全新实体 `EntryTemplate`、`Category` / `Account` 各加一个可选 to-many。
//  这些**全部落在轻量迁移范围内**（原地 `ALTER TABLE` 加列 + 建新表），因此不需要自定义
//  `MigrationStage` 的 `willMigrate` / `didMigrate` 闭包。
//
//  ## `stages` 为什么保持 `[]`（与架构 D1 一致，且经过实测）
//
//  团队一度决定把 `stages` 从 `[]` 改成显式一段
//  `.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)`，
//  理由是"把迁移路径写进代码，不赌隐式行为"。**这个改法在本工程里必然崩溃**，实测报错原文：
//
//      *** Terminating app due to uncaught exception 'NSInvalidArgumentException',
//          reason: 'Duplicate version checksums detected.'
//          ...
//          NSLightweightMigrationStage … -[NSPersistentStoreCoordinator migrateStoreWithContext:error:]
//
//  原因是 `VersionedSchema.models` 里放的是**当前**的 `@Model` 类，而 `SchemaV1` 与 `SchemaV2`
//  引用的是同一批类；`Category.templates` / `Account.templates` 的 `inverse:` 指向
//  `EntryTemplate`，SwiftData 生成 V1 的 CoreData 模型时会把反向关系的目标实体一并拉进来——
//  于是 V1 的模型实际上已经包含 `EntryTemplate`，与 V2 的模型**逐字节相同**，
//  校验和重复，CoreData 直接拒绝。实测三组探针（同一台机器、同一条命令）：
//
//  | V1 声明                        | V2 声明                                   | 结果             |
//  | ------------------------------ | ----------------------------------------- | ---------------- |
//  | 6 模型（真实）                 | 6 模型 + `EntryTemplate`（真实）           | 崩溃：校验和重复 |
//  | `[LedgerEntry]`                | 6 模型 + `EntryTemplate`                  | 通过             |
//  | `[Account, Category]`          | `[Account, Category, EntryTemplate]`      | 崩溃：校验和重复 |
//
//  第三组是决定性证据：两个字面量只差一个显式实体，仍然被判为同一版，说明 V1 的模型被
//  反向关系隐式撑大。所以"显式 lightweight stage"在当前写法下无法成立；要使它成立，必须把
//  1.0.0 的六个模型**复制一份**放进 `SchemaV1`（Apple 官方迁移样例的做法），
//  代价是每个 schema 版本永久多维护一套模型副本——V1.1 不做这个投入（架构 R4 的取舍）。
//
//  回退到 `[]` 的代价：迁移路径依赖 SwiftData 的隐式轻量迁移。这个路径本身是安全的
//  （全部改动都在轻量迁移白名单内：加列 / 加表 / 加可选 to-many），
//  且 `ModelContainerTests.testSchemaV1DeclaresSixModels` 会盯住 `stages.isEmpty`——
//  将来若要加 `.custom`（非轻量迁移），那条断言会先变红，不会悄悄上线。
//
//  ⚠️ 与架构文档 D1 的差异（以团队决策为准）：D1 原本要求 `Diagnostics` 停在
//  `SchemaV1.models.count`。V1.1 的实现仍推翻了这一点：自检日志必须反映真实的模型数（7），
//  否则自检报告会和实际数据库结构对不上。代价是既有测试里 2 处"模型数是 6"的断言同步改。
//

import Foundation
import SwiftData

/// schema 第 1 版：六个模型。
///
/// **原样保留，不得修改**：它是迁移链的起点，`schemas` 里必须能看到"旧库长什么样"。
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

/// schema 第 2 版：V1 的六个模型 + 记账模板（共七个）。
///
/// V1.1 的五项功能只带来两类 schema 变更：
/// - `LedgerEntry` 加 `confirmRaw`（订阅账目待确认）与 `deletedDay`（最近删除的整数谓词哨兵）；
/// - 新增 `EntryTemplate` 实体（常用记账模板），并给 `Category` / `Account` 各加一个
///   `templates` 反向关系（CloudKit 要求每个 to-many 显式 `inverse:`）。
///
/// 全部是"加列 / 加表"，没有改类型、没有删字段、没有给标量加非默认约束，
/// 因此两版之间走的是**隐式轻量迁移**（`stages` 保持 `[]`，理由见文件头注释）。
enum SchemaV2: VersionedSchema {

    /// 版本号 2.0.0。
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    /// 本版包含的全部模型（7 个）。
    ///
    /// 顺序沿用 V1 的前六个，`EntryTemplate` 追加在末尾——
    /// 这样 `git diff` 只有一行新增，人工核对时不会误以为既有模型顺序变了。
    static var models: [any PersistentModel.Type] {
        [
            LedgerEntry.self,
            Account.self,
            Category.self,
            Subscription.self,
            Todo.self,
            AppSettings.self,
            EntryTemplate.self
        ]
    }
}

/// 迁移计划：`[V1, V2]`，`stages` 留空交由 SwiftData 做隐式轻量迁移。
///
/// `stages` 为什么不能显式声明 `.lightweight(fromVersion:toVersion:)`——
/// 见文件头「`stages` 为什么保持 `[]`」：两版引用同一批 `@Model` 类，
/// 反向关系会把 `EntryTemplate` 拉进 V1 的模型，导致校验和重复并崩溃。
enum YiZhangMigrationPlan: SchemaMigrationPlan {

    /// 迁移链：旧库在 V1，新代码用 V2。
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }

    /// 迁移段：留空。V1 → V2 的全部改动都在轻量迁移白名单内，SwiftData 会自动完成。
    static var stages: [MigrationStage] { [] }
}
