# 项目长期记忆

## 身份
- 产品名：**一账**（2026-11-24 由「一事」改名）
- 英文/工程名：`YiZhang`；Bundle ID：`com.xiaoban.yizhang`
- 工作空间：`~/Desktop/小半工作室/一账`
- 技术栈：SwiftUI + SwiftData + Swift Charts，iOS 17+，零第三方依赖

## 构建 / 测试
```
cd ~/Desktop/小半工作室/一账
xcodebuild -project YiZhang.xcodeproj -scheme YiZhang \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-disable-sandbox
```
- `OTHER_SWIFT_FLAGS=-disable-sandbox` 必带，否则 SwiftData 宏展开失败
- 模拟器 `iPhone 17 Pro`；截图 `xcrun simctl io booted screenshot`
- **`-destination` 带上 `OS=26.5`**。只写 `name=iPhone 17 Pro` 时，若机器上有损坏的 iOS 27.x 运行时，
  会报一个莫名其妙的 macOS/My Mac 错误（实测根因是运行时损坏，不是工程配置）
- UI 测试独立跑：`-only-testing:YiZhangUITests` 且 `OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`，
  12 条约 150 秒。单测基线 **694** 条
- Debug 构建的业务代码在 `YiZhang.debug.dylib` 里，`strings`/`grep -a` 查符号必须查这个 dylib，且要带正对照

## 版本控制
- 远程仓库：`https://github.com/ytywxw/yizhang`（origin 实际配为 SSH：`git@github.com:ytywxw/yizhang.git`，本机 SSH key 已授权 ytywxw）
- 主分支 `main`，已 `-u` 绑定 `origin/main`
- **用户说「提交」= 提交并推送到这个仓库**，不用再问推哪里

## 数据层铁律（踩过坑，别再踩）
- **`SchemaMigrationPlan.stages` 必须为空数组**。写显式 `.lightweight(...)` 会在启动时崩：
  `NSInvalidArgumentException: Duplicate version checksums detected.`
  原因：`VersionedSchema.models` 持有的是**当前** `@Model` 类，`Category.templates` / `Account.templates`
  的 `inverse:` 把 `EntryTemplate` 也拉进 V1 实体集 → 两版 checksum 逐字节相同。
  三组探针矩阵记在 `Core/Persistence/SchemaV1.swift` 文件头。
- 软删用 `deletedDay: Int32 = 0` 哨兵做谓词过滤，`deletedAt: Date?` 只做内存排序。
  **`Optional<Date>` 绝不能进非等值谓词**（iOS 17 会崩）。
- 7 个 `@Model`：`LedgerEntry` / `Account` / `Category` / `Subscription` / `Todo` / `AppSettings` / `EntryTemplate`。
  全部标量带字面量默认值、零 `.unique`/`.deny`/`.cascade`、to-many 全显式 `inverse:`。

## 测试约定
- **断言金额时不要自己 `reduce` 手算，走生产聚合函数**（如 `StatisticsCalculator.totals`）。
  手算会让「测试算错」和「实现漏写」互相掩盖。
- 写 ViewModel 层断言，别只测 Service 层：接线错了（字段没赋值）Service 测试仍全绿。
- 加字段到值类型时，若既有测试用全参数调用，字段必须是 `var` + 默认值，
  否则 `let` 有默认值会被剔出 memberwise init，几十处调用点编译失败。

## 规矩
- 改名类批量替换禁止模糊匹配中文词，先列出精确形态再改（「同一事务」「一件事」「这一事实」都含「一事」子串）
- 用户逐项授权做事（「我说做哪些你再做」）时，不得自己扩展范围；超出部分记 V1.2 候选，不顺手加
