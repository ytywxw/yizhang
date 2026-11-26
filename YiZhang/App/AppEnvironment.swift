//
//  AppEnvironment.swift
//  一账 / App
//
//  职责：依赖容器 + 数据变更广播（进程级唯一的"服务注册表"）。
//
//  为什么不用单例、也不用 7 个 EnvironmentKey（架构 §4.3）：
//  ① 单例让 ViewModel 无法在测试里换成 in-memory 容器；
//  ② 7 个 EnvironmentKey 会有 7 份样板，新增一个 Service 要改 3 处（定义/注入/读取）。
//  用 `@Observable` + `.environment(env)` 注入整棵树，ViewModel 用
//  `@Environment(AppEnvironment.self)` 取依赖，每个 VM 都能在测试里用真依赖组装。
//
//  `dataVersion` 是"缓存失效信号"：任何写入提交后自增，统计页用 `.task(id: dataVersion)` 重新取数。
//  为什么不用 `@Query` 直接刷新统计：统计需要聚合（不能直接绑 UI），且聚合必须限定区间。
//
//  已注册：`LedgerService`（T06）、`SubscriptionService` + `SweepCoordinator`（T10/T11）、
//  `TodoService`（T15）、`TemplateService` + `TrashService`（V1.1 / T1）。
//  其余 Service 的预留位置见「后续扩展」注释。
//

import Foundation
import Observation
import SwiftData

/// 启动装配错误。
enum AppEnvironmentError: LocalizedError {
    /// 种子数据没有产生设置行（正常不会发生）
    case missingSettings
    /// 容器创建失败（磁盘损坏 / 迁移失败）
    case containerUnavailable(underlying: String)

    var errorDescription: String? {
        switch self {
        case .missingSettings:
            return "设置数据缺失，请重新打开 App"
        case .containerUnavailable(let reason):
            return "本地数据库无法打开：\(reason)"
        }
    }
}

/// 依赖容器。
@MainActor
@Observable
final class AppEnvironment {

    // MARK: - 依赖

    /// 唯一容器（`.modelContainer(_:)` 注入 SwiftUI 环境也用它）。
    let container: ModelContainer

    /// 写入器（唯一写入口，A3 铁律）。
    ///
    /// 暴露出来是给"账户 / 分类管理"这类**非账目**写入用的：
    /// 它们不属于记账业务，但同样必须走同一个 context 与同一次 `save()`，
    /// 否则会出现"账户改名了但账目那边还是旧引用"这种半成品状态。
    let writer: LedgerWriter

    /// 记账服务。
    let ledger: LedgerService

    /// 订阅服务（新建 / 编辑 / 状态机 / 已续费 / 补录）。
    let subscription: SubscriptionService

    /// 结算扫描（到期自动记账的唯一写入点）。
    let sweep: SweepCoordinator

    /// 本地通知服务（T20）：订阅扣费 / 到期 / 待办截止。
    ///
    /// 它**不参与任何业务写入**：通知发不出去不影响记账与扫描（硬要求）。
    let notifications: NotificationService

    /// 应用锁（T21）：本地防窥，默认关闭。放在 env 里而不是某个页面的 `@State`，
    /// 因为锁定遮罩要盖在整个 App 上，设置页只是它的一个开关入口。
    let appLock: AppLockService

    /// 待办服务（T15）：增删改 + 两步完成 + 撤销完成 + 重复实例。
    ///
    /// 跟 `subscription` 共用同一个 `writer`：待办完成时写的那笔账必须和
    /// `linkedEntryID` 回写落在同一个 `save()` 里，否则会出现"账目有、关联没写"的悬空记录。
    let todo: TodoService

    /// scenePhase 协调器（冷启动扫描、自检的挂载点）。
    let sceneCoordinator: ScenePhaseCoordinator

    /// 常用模板服务（V1.1 / F-ACC-14）。
    ///
    /// 与其它服务共用同一个 `writer`：模板的增删改与账目写入共享"一次 save = 一个事务"，
    /// 于是"存为模板"这类复合动作不会出现半成品。
    let template: TemplateService

    /// 最近删除服务（V1.1 / 最近删除）。
    ///
    /// 持有 `subscription` 是为了恢复订阅账目时能回退抑制表（`unsuppress`）——
    /// 这是 PRD 6.3-1 的硬要求，不是可选优化。
    let trash: TrashService

    /// 设置行（单例，由 `SeedData` 幂等保证）。
    ///
    /// 单独一个 context 持有：设置页直接绑字段 + `saveSettings()`，
    /// 避免把"改开关"这种低频写入挤进 `LedgerWriter` 的记账事务里。
    private(set) var settings: AppSettings

    /// **只读上下文**：给 Features / ViewModel 做一次性查询（分类、账户、账目、待办、订阅）。
    ///
    /// 与 `LedgerWriter` 的写上下文分离，读写互不干扰：
    /// ① A3 铁律不变——**写入只有 `LedgerWriter` 一个入口**，本上下文绝不调用 `save()`；
    /// ② 读走独立上下文后，ViewModel 不需要为了列一下分类而去碰写上下文，
    ///    也就不会出现"改了一个属性忘了 save，下一次 `LedgerWriter.save()` 把它顺手提交"的事故；
    /// ③ 本上下文只做 `fetch`，是"一次性查询"，不参与 UI 的自动刷新
    ///    （刷新由 `dataVersion` 信号驱动）。
    ///
    /// **每次写入提交后整只换新**（见 `bumpDataVersion()`）：`var` 而不是 `let` 就是为了这个。
    /// 长生命周期的只读上下文会把 `Account` / `Category` 这些关系端对象登记在自己的
    /// identity map 里，写上下文 `save()` 之后重新 `fetch`，拿回来的还是**同一个旧实例**，
    /// 属性是旧快照 —— "改名后刷新仍是旧名"就是这么来的。
    private(set) var readContext: ModelContext

    /// 数据版本号：任何写入提交后自增，供需要手动刷新的页面（统计页）当失效信号。
    private(set) var dataVersion: Int = 0

    /// 最近一次启动自检的结果（T23）。Release 里只有它，不做任何修复。
    private(set) var lastDiagnostics: Diagnostics.Report?

    /// 当前选中的 Tab。
    ///
    /// 放在这里而不是 `RootTabView` 的私有 `@State` 里，是因为**跨页跳转**需要它：
    /// 导出页的"还没有账目"空态、统计页的"去记一笔"，都要能把用户送到账本页。
    /// 用一个共享的 observable 属性，比把 `onGoTo` 闭包一层层往下传干净得多。
    var selectedTab: AppTab = .ledger

    // MARK: - 通知重算

    /// 全量重算本地通知（冷启动 / 回前台 / 设置页手动刷新都走这里）。
    ///
    /// 输入全部来自只读上下文：订阅快照 + 未完成待办。**本方法不抛错**——
    /// 通知是增强功能，任何失败都不该冒泡到业务层。
    @discardableResult
    func rescheduleNotifications(today: DateOnly = DateOnly(Date())) async -> Int {
        let subscriptions = (try? readContext.fetch(QueryDescriptors.allSubscriptions())) ?? []
        let snapshots = subscriptions.map { SubscriptionMapper.snapshot(of: $0) }

        let todos = (try? readContext.fetch(QueryDescriptors.openTodos())) ?? []
        let seeds = todos.map {
            NotificationPlanner.TodoSeed(
                id: $0.id,
                title: $0.displayTitle,
                dueDay: $0.dueDay,
                dueTimeMinutes: $0.dueTimeMinutes,
                isDone: $0.isDone
            )
        }

        return await notifications.rescheduleAll(
            subscriptions: snapshots,
            todos: seeds,
            today: today
        )
    }

    private let settingsContext: ModelContext

    // MARK: - 后续扩展的接线点（下一批按顺序填，不需要改本类以外的地方）
    //
    // let statistics需要单独的 Service 吗？T19 的聚合是纯函数（`StatisticsCalculator`），
    // ViewModel 直接取数调用，不需要注册成 Service。
    // let exporter: ExportService              // T22
    //
    // 接入方式统一为：在 `init` 里用同一个 `container` 构造，并把 `onDidCommit`
    // 接到 `{ [weak self] in self?.bumpDataVersion() }`——本批 `ledger`/`subscription`/`sweep`
    // 已按此模式接好。

    // MARK: - 初始化

    /// 组装全部依赖。
    ///
    /// 顺序是有意义的：**先种子，再服务**——服务初始化时就可能读分类/账户（如默认分类）。
    ///
    /// - Parameter container: 已建好的容器。
    init(container: ModelContainer) throws {
        self.container = container

        // 1. 首启种子（幂等：连跑两次不会重复插入）
        try SeedData.seedIfNeeded(in: container)

        // 1.5 只读上下文（必须在种子之后建，保证一上来就能读到预置分类/账户）
        self.readContext = ModelContext(container)

        // 2. 写入器 + 记账服务（唯一写入口）
        let writer = LedgerWriter(container: container)
        self.writer = writer
        let ledgerService = LedgerService(writer: writer)
        self.ledger = ledgerService

        // 3. 订阅服务与结算扫描（共用同一个 writer，保证"一次 save = 一个事务"）
        let subscriptionService = SubscriptionService(writer: writer, ledger: ledgerService)
        self.subscription = subscriptionService
        let sweepCoordinator = SweepCoordinator(writer: writer)
        self.sweep = sweepCoordinator

        // 3.5 待办服务（与订阅共用 writer，理由见 `todo` 属性的注释）
        let todoService = TodoService(writer: writer, ledger: ledgerService)
        self.todo = todoService

        // 3.6 通知服务（只读数据 + 系统通知中心，不碰 writer）
        self.notifications = NotificationService()

        // 3.7 应用锁（与数据无关，只读写 UserDefaults）
        self.appLock = AppLockService()

        // 3.8 模板服务（V1.1）：与账目写入共用 writer，"存为模板"不会写出半成品
        let templateService = TemplateService(writer: writer)
        self.template = templateService

        // 3.9 最近删除服务（V1.1）：恢复订阅账目时要回退抑制表，因此依赖 subscriptionService
        let trashService = TrashService(writer: writer, subscription: subscriptionService)
        self.trash = trashService

        // 4. 设置行
        let context = ModelContext(container)
        guard let loadedSettings = try context.fetch(QueryDescriptors.appSettings()).first else {
            throw AppEnvironmentError.missingSettings
        }
        self.settingsContext = context
        self.settings = loadedSettings

        // 5. scenePhase 协调器（弱引用回指，避免 env ↔ coordinator 循环持有）
        let coordinator = ScenePhaseCoordinator()
        self.sceneCoordinator = coordinator
        coordinator.attach(self)

        // 6. 写入成功 → 广播（Service 不反向持有 env）
        ledgerService.onDidCommit = { [weak self] in
            self?.bumpDataVersion()
        }
        subscriptionService.onDidCommit = { [weak self] in
            self?.bumpDataVersion()
        }
        sweepCoordinator.onDidCommit = { [weak self] in
            self?.bumpDataVersion()
        }
        todoService.onDidCommit = { [weak self] in
            self?.bumpDataVersion()
        }
        templateService.onDidCommit = { [weak self] in
            self?.bumpDataVersion()
        }
        trashService.onDidCommit = { [weak self] in
            self?.bumpDataVersion()
        }

        // 6.1 每次软删之后清一次回收站（PRD 6.2 的第二个挂载点）。
        //
        // 三个 Service 各自只有一个软删入口（`LedgerService.delete`、
        // `SubscriptionService.denyEntry`、`TodoService.reopen(keepEntry: false)`），
        // 全部接到同一个钩子：过期项只可能由"时间"产生，但容量兜底（> 500 条）
        // 需要每次删除后重算，两条逻辑在 `purgeExpired` 里本来就是一件事。
        //
        // **best-effort**：`try?` 吞掉异常。清理失败最多让过期项多留到下次冷启动，
        // 绝不能因为它把用户刚才的删除动作变成一次失败的写入。
        let purgeExpiredTrash: () -> Void = { [weak self] in
            guard let self else { return }
            _ = try? self.trash.purgeExpired(today: DateOnly(Date()))
        }
        ledgerService.onDidSoftDelete = purgeExpiredTrash
        subscriptionService.onDidSoftDelete = purgeExpiredTrash
        todoService.onDidSoftDelete = purgeExpiredTrash

        // 7. 开发期演示数据（仅 DEBUG，且必须显式传启动参数；详见 `DebugDemoData`）
        #if DEBUG
        DebugDemoData.seedEntriesIfRequested(ledger: ledgerService, writer: writer)
        DebugDemoData.seedArchivedAccountIfRequested(writer: writer)
        DebugDemoData.seedStatisticsIfRequested(ledger: ledgerService, writer: writer)
        DebugDemoData.seedPerformanceDataIfRequested(ledger: ledgerService, writer: writer)
        DebugDemoData.applyNotificationOverrideIfRequested()
        DebugDemoData.seedSubscriptionsIfRequested(
            subscription: subscriptionService,
            sweep: sweepCoordinator,
            writer: writer
        )
        DebugDemoData.seedTodosIfRequested(todo: todoService)
        // UI 测试专用：chips 与删除弹层都需要"非空数据"才可达
        // （`TemplateChipsRow` 空模板整行不渲染；删除弹层全部门禁在 `isRepeating` 上）
        DebugDemoData.seedTemplatesIfRequested(template: templateService, writer: writer)
        DebugDemoData.seedRepeatingTodosIfRequested(todo: todoService, writer: writer)
        #endif
    }

    // MARK: - 启动自检

    /// 跑一次自检并记下结果。
    ///
    /// 自检**永不抛错到调用方**：它是一道保险，不是业务流程的一环。
    /// 库打不开这种致命问题在 `init` 阶段就已经失败了，能走到这里的只有数据本身的问题。
    @discardableResult
    func runDiagnostics() -> Diagnostics.Report? {
        let report = try? Diagnostics.run(in: container)
        lastDiagnostics = report
        return report
    }

    // MARK: - 变更广播

    /// 手动推进数据版本（写入路径统一调用；预留给未来的批量写入方）。
    ///
    /// ## 为什么除了自增版本号，还要**换一只新的只读上下文**
    ///
    /// `readContext` 与 `LedgerWriter` 是两个 ModelContext。SwiftData **不会**把
    /// 一边 `save()` 的结果合并到另一边已登记的对象上：写上下文里把账户名从
    /// 「现金」改成「微信零钱」并提交之后，只读上下文再 `fetch` 账目，关系上挂回来的
    /// 仍是**同一个旧 `Account` 实例**，`displayName` 还是「现金」。
    ///
    /// 实测过 `rollback()`：它只丢弃未提交的改动，对没有改动的只读上下文不刷新已登记
    /// 对象，救不了这个（端到端用例 `testR2b_...` 就是证据）。所以这里直接换一只新
    /// context —— 新上下文没有任何登记对象，`fetch` 只能从库里读，必然是新值。
    ///
    /// 这不是"顺手清缓存"，它是**正确性**的一部分：`dataVersion` 只负责通知页面重算，
    /// 而重算能不能读到新值取决于上下文是否干净。两者缺一，改名在列表里就是"不生效"。
    ///
    /// 代价：每次写入提交后重建一次上下文（一次分配，不读数据），只发生在用户动作之后，
    /// 不在渲染路径上。
    func bumpDataVersion() {
        dataVersion &+= 1
        readContext = ModelContext(container)
    }

    // MARK: - 设置

    /// 提交设置改动。设置页的开关直接改 `settings` 字段，然后调这里。
    ///
    /// 失败时只忽略（`try?`）：开关这种 UI 状态不该弹错误弹窗，最坏情况是下次启动回滚。
    func saveSettings() {
        try? settingsContext.save()
    }

    /// 重新读取设置（外部改动后同步内存副本）。
    func reloadSettings() {
        if let refreshed = try? settingsContext.fetch(QueryDescriptors.appSettings()).first {
            settings = refreshed
        }
    }
}
