//
//  Acceptance_RegressionTests.swift
//  YiZhangTests / Acceptance
//
//  职责：把验收过程中发现的**源码缺陷**固化成可重复运行的回归测试。
//
//  ## 这些用例现在断言的是"已修好的行为"
//
//  每一条都曾用 `XCTExpectFailure(strict: false)` 包着，用来固定验收挖出的真实缺陷：
//  ① 缺陷有可执行证据，不是报告里的一句描述；
//  ② 套件保持绿色，工程师不会为了"修测试"而分心——要修的是源码。
//
//  **缺陷全部已修，期望包装已全部删除**：断言现在真的生效，谁把判据改回去就直接变红。
//  保留"已修复"的用例而不是删掉它，是因为这里复现的多是**时序与口径**而不是语法：
//  - 时序：页面存活期间的外部写入（读缓存快照的计数就会重现 P1/P2）；
//  - 口径：同一件事被两处各数一套就会重现 P3。
//  任何一次"为了性能把计数改成走缓存""把两个计数合成一个快照"的重构都会重新引入。
//
//  ## 已覆盖的缺陷
//
//  1. **P1** 账户页计数过期 → 有账目的账户被真删（违反 PRD §3.5 只能归档）；
//  2. **P2** 分类页计数过期 → 分类被真删，留下 `category == nil` 的账目（违反 R-CAT-2）；
//  3. **P3** 弹窗判据与服务层判据**口径不同**（前者只数未删、后者含软删）→
//     只有软删账目的分类，弹窗说"没有账目"、点删除却报"请选迁移目标" → 死路；
//  4. **R2** 账户 / 分类页直写 `writer`，改完不 `bumpDataVersion()` →
//     改名后账本列表的行名快照一直是旧名。
//
//  ## P1 / P2 的共同根因
//
//  `AccountManageViewModel` / `CategoryManageViewModel` 的 `rows` 只在 `attach()`
//  和自身写操作之后 `load()`。**页面存活期间由外部写入**（从后台回前台触发
//  `SweepCoordinator.sweep()` 落订阅账目，是最真实的路径）时，`entryCount` 是旧值，
//  于是 `deletePreview` 把"有账目的账户/分类"误判成"空"，走了真删分支。
//
//  修法：分支判据不再读 `rows`，改为**在 `delete(id:)` 里现数**。
//
//  P1/P2 的后果不是丢账目（关系是 `.nullify`，账目还在），而是：
//  - 账户：账目详情里的账户变成空；
//  - 分类：产生**无分类账目**，统计的"支出分类占比"里会多出一个没有名字的桶。
//

import XCTest
@testable import YiZhang

@MainActor
final class Acceptance_RegressionTests: XCTestCase {

    // MARK: - P1：账户页计数过期 → 有账目的账户被真删

    /// 复现路径（与真实交互一致）：
    /// 1. 进入「我的 → 账户」，页面 attach，此时该账户 0 笔账目；
    /// 2. **页面停留不动**，App 回到前台触发 sweep，写入 1 笔订阅账目；
    /// 3. 用户点删除 → 必须走归档分支。
    func testP1_StaleAccountEntryCountHardDeletesAccountThatHasEntries() throws {
        let world = try AcceptanceWorld.boot()
        let viewModel = AccountManageViewModel()
        viewModel.attach(world.env)

        // attach 之后才出现的账目 = 页面里的旧快照看不到它
        let account = try world.firstAccount()
        let previewAtAttach = viewModel.deletePreview(for: account.id)
        XCTAssertEqual(previewAtAttach?.entryCount, 0, "前置条件：attach 时账户下确实没有账目")

        let entryID = try world.manual(amount: 2_500, day: 20261120, note: "页面存活期间 sweep 写入")
        XCTAssertEqual(try world.entries().count, 1)

        // 正确行为：有 1 笔账目的账户只能归档（PRD §3.5）
        let outcome = try viewModel.delete(id: account.id)
        XCTAssertEqual(
            outcome, .archived(entryCount: 1),
            "有账目的账户应归档而不是真删（分支判据必须现数，不能读页面快照）"
        )
        let entry = try world.entry(id: entryID)
        XCTAssertEqual(
            entry?.account?.id, account.id,
            "归档后账目仍应挂在这个账户上"
        )
    }

    // MARK: - P2：分类页计数过期 → 分类被真删，留下无分类账目

    /// 与 P1 同根因，但后果更重：删掉分类后账目变成「无分类」，
    /// 违反 R-CAT-2（不允许无分类账目），统计里会出现无名分类桶。
    func testP2_StaleCategoryEntryCountHardDeletesCategoryAndOrphansEntries() throws {
        let world = try AcceptanceWorld.boot()
        let viewModel = CategoryManageViewModel()
        viewModel.attach(world.env)

        let categoryID = try viewModel.create(
            name: "验收临时分类",
            type: .expense,
            iconName: "tag",
            colorHex: "#8E8E93"
        )

        // 分类创建后、页面不 reload 的情况下写入账目
        let entryID = try world.manual(amount: 1_200, day: 20261120, note: "临时分类下的账目", categoryID: categoryID)
        // 前置条件是**页面快照过期**，不是"preview 说没账目"——P3 修完之后
        // preview 也走现数，它会立刻看到这 1 笔。这里钉的是 `rows` 仍为 0 这一事实。
        XCTAssertEqual(
            viewModel.rows(for: .expense).first(where: { $0.id == categoryID })?.entryCount, 0,
            "前置条件：页面里的快照仍显示 0 笔账目（rows 只在 attach / 自身写操作后刷新）"
        )

        // 正确行为：应该抛 `migrationTargetRequired`，逼用户选迁移目标
        XCTAssertThrowsError(
            try viewModel.delete(id: categoryID),
            "有账目的分类不带迁移目标时应当拒绝删除（分支判据必须现数）"
        ) { error in
            XCTAssertEqual(
                error as? CategoryManageError, .migrationTargetRequired,
                "必须是「请先选一个迁移目标」，不能是别的错误"
            )
        }
        let entry = try world.entry(id: entryID)
        XCTAssertNotNil(entry?.category, "R-CAT-2：账目不允许无分类")
        XCTAssertEqual(entry?.category?.id, categoryID, "拒绝删除后分类应与账目原样保留")
    }

    // MARK: - P1b：转账的**目标**账户同样算"有账目"

    /// 第 2 轮补的边角：删除账户时，引用它的不只是"转出"的账目，
    /// **转入**到它的转账也引用它（`toAccount`）。删掉目标账户，这笔转账会失去目标，
    /// 详情里「转入」变成空。
    ///
    /// 构造：A 账户 3 笔转给 B，B 自己 0 笔支出 → 删 B 必须是归档，且账目仍指向 B。
    /// 同样在 `attach()` 之后才写入，以覆盖"页面快照过期"的时序。
    func testP1b_DeletingTransferTargetAccountArchivesInsteadOfHardDelete() throws {
        let world = try AcceptanceWorld.boot()
        let viewModel = AccountManageViewModel()
        viewModel.attach(world.env)

        let target = try world.secondAccount()   // B：只有转入，没有转出
        XCTAssertEqual(
            viewModel.deletePreview(for: target.id)?.entryCount, 0,
            "前置条件：attach 时 B 名下确实没有账目（弹窗会说「没有任何账目」）"
        )

        var transferIDs: [UUID] = []
        for day in [Int32(20261110), 20261112, 20261115] {
            transferIDs.append(try world.transfer(amount: 10_000, day: day))
        }

        let outcome = try viewModel.delete(id: target.id)
        XCTAssertEqual(
            outcome, .archived(entryCount: 3),
            "3 笔转账转入 B，删 B 必须归档；返回的条数要含转入（与列表口径一致）"
        )

        for id in transferIDs {
            let entry = try world.entry(id: id)
            XCTAssertEqual(entry?.toAccount?.id, target.id, "归档后转账的收款账户仍在")
        }
        XCTAssertEqual(try world.accounts().filter { $0.id == target.id }.first?.isArchived, true)
    }

    // MARK: - P3：只有软删账目的分类 —— 服务层挡住了，但 UI 不给出口

    /// 本轮修复把分类的计数口径改成「未删 + 已删」，这一步是对的：
    /// 软删的账可撤销，硬删掉它引用的分类，恢复出来就是一条无分类账目。
    ///
    /// 但**弹窗的判据仍然是 UI 快照**（`allRows` 只数未删账目），于是出现口径差：
    /// - `deletePreview` → `.direct`（"没有任何账目"）；
    /// - `delete(id:)` → 抛 `migrationTargetRequired`。
    ///
    /// 结果：用户看到的是"删除分类"直接确认弹窗（没有「迁移到」区），点删除只得到一行
    /// 红字「请先选择迁移目标」，而这个弹窗里根本没有地方可以选 —— **死路**，
    /// 退出重进也一样（重进后 rows 仍只数未删，preview 仍是 `.direct`）。
    ///
    /// 数据没坏（服务层挡住了），属于交互死路，列「次要」。
    func testP3_CategoryWithOnlySoftDeletedEntriesIsADeadEndInUI() async throws {
        let world = try AcceptanceWorld.boot()
        let viewModel = CategoryManageViewModel()
        viewModel.attach(world.env)

        let categoryID = try viewModel.create(
            name: "验收软删分类",
            type: .expense,
            iconName: "tag",
            colorHex: "#8E8E93"
        )
        let entryID = try world.manual(
            amount: 1_500, day: 20261120, note: "记完又删掉", categoryID: categoryID
        )
        // 用户把这笔账删了（软删，可撤销）
        let token = await world.env.ledger.delete(id: entryID)
        XCTAssertNotNil(token, "前置条件：账目被软删")

        // 重新 load，排除"页面快照过期"的干扰——这里要比的是**口径**，不是时序
        viewModel.load()

        // 服务层：正确挡住（软删账目恢复后会变孤儿）
        XCTAssertThrowsError(try viewModel.delete(id: categoryID)) { error in
            XCTAssertEqual(
                error as? CategoryManageError, .migrationTargetRequired,
                "服务层应要求迁移目标（这半边是对的）"
            )
        }

        // 但 UI 判据与之矛盾：preview 说「没有账目」，弹窗不会给迁移区
        XCTAssertEqual(
            viewModel.deletePreview(for: categoryID),
            .requiresMigration(name: "验收软删分类", entryCount: 1),
            "删除弹窗的判据必须与服务层同口径（含软删），否则用户没有出口"
        )

        // 无论上面怎么判，账目不能被弄成无分类
        XCTAssertEqual(try world.entry(id: entryID)?.category?.id, categoryID)
    }

    // MARK: - M1：来源被删后，账目这一侧的数据前提

    /// 明细页「来自」的可点判据是两项：`sourceRefID != nil` **且** 源对象没被删。
    /// 点击本身在渲染层，单测合成不了；但**数据前提**可以钉住：
    /// 删掉订阅之后，账目仍然留着 `sourceRefID`（能说清"来自哪个订阅"），
    /// 而订阅已经查不到 —— 于是详情页会走 `isSourceDeleted == true` 的纯文本分支。
    ///
    /// 这条同时守住一个坑：删订阅不能顺手把账目的 `sourceRefID` 抹掉，
    /// 抹掉之后详情页只能显示"（已删除）"却说不清是哪一笔。
    func testM1_DeletingSourceKeepsReferenceButFlipsTheClickableCriterion() throws {
        let world = try AcceptanceWorld.boot()
        let today = AcceptanceToday.value
        let account = try world.firstAccount()

        let created = try world.env.subscription.create(
            SubscriptionDraft(name: "要删掉的订阅", amount: 2_500, firstBillingDay: 20261115, accountID: account.id),
            today: today
        )
        XCTAssertEqual(world.env.sweep.sweep(today: today, force: true).inserted, 1)

        let entry = try XCTUnwrap(try world.entries(ofSource: .subscription).first)
        XCTAssertEqual(entry.sourceRefID, created.subscriptionID, "生成时写入了来源 ID")

        try world.env.subscription.delete(id: created.subscriptionID)

        let afterDelete = try XCTUnwrap(try world.entry(id: entry.id))
        XCTAssertEqual(
            afterDelete.sourceRefID, created.subscriptionID,
            "删订阅不能抹掉账目的 sourceRefID，否则详情页说不清「来自哪儿」"
        )
        XCTAssertEqual(afterDelete.amount, 2_500, "账目本身不受影响")
        // 源已查不到 ⇒ 详情页 resolveSource 会给出 isDeleted = true ⇒ 渲染成纯文本
        let source = try world.env.readContext
            .fetch(QueryDescriptors.subscription(id: created.subscriptionID))
            .first
        XCTAssertNil(source, "前置条件：订阅已删除，详情页据此把「来自」渲染成不可点的纯文本")
    }

    // MARK: - R1：`.task(id: dataVersion)` 不会自激成死循环

    /// `.task(id: environment.dataVersion) { viewModel.load() }` 的安全性完全取决于一件事：
    /// **`load()` 不能改 `dataVersion`**。改了就是"刷新 → 版本变 → 再刷新"的自激循环。
    ///
    /// 这里按 SwiftUI 的语义走一遍：`.task(id:)` 只在 id 变化时重跑。
    /// 用 `runs` 计"重跑了几次"，正常应该是 1 次（首次出现），然后 id 不动、停下来。
    func testR1_LoadDoesNotBumpDataVersionSoRefreshCannotSelfTrigger() throws {
        let world = try AcceptanceWorld.boot()
        _ = try world.manual(amount: 1_000, day: 20261120, note: "让 rows 非空")

        let accountVM = AccountManageViewModel()
        accountVM.attach(world.env)
        let categoryVM = CategoryManageViewModel()
        categoryVM.attach(world.env)

        let accountID = try world.firstAccount().id
        let baseline = world.env.dataVersion

        // 模拟 `.task(id: dataVersion)`：跑一次 → 看 id 变没变 → 没变就停
        var runs = 0
        var observed = baseline
        while runs < 5 {
            accountVM.load()
            categoryVM.load()
            _ = accountVM.deletePreview(for: accountID)
            _ = categoryVM.deletePreview(for: try world.defaultExpenseCategory().id)
            runs += 1
            guard world.env.dataVersion != observed else { break }
            observed = world.env.dataVersion
        }
        XCTAssertEqual(runs, 1, "load() 若 bump dataVersion，.task(id:) 会自激；这里是死循环的探针")
        XCTAssertEqual(world.env.dataVersion, baseline, "纯读取路径不得推进 dataVersion")

        // 对照：经 Service 的写入 bump 恰好一次，随后再 load 也不再变化（收敛，不是振荡）
        let beforeServiceWrite = world.env.dataVersion
        _ = try world.manual(amount: 800, day: 20261120, note: "经 LedgerService 写入")
        let afterServiceWrite = world.env.dataVersion
        XCTAssertGreaterThan(afterServiceWrite, beforeServiceWrite, "Service 写入应广播一次 refresh")
        accountVM.load()
        categoryVM.load()
        XCTAssertEqual(world.env.dataVersion, afterServiceWrite, "刷新自己不得再产生新的 refresh")
    }

    // MARK: - R2：账户/分类页的写入没有广播（让 .task(id:) 刷不到别的页）

    /// 第 2 轮查 `.task(id: dataVersion)` 时发现的**口径缺口**（不是本轮引入的回归）：
    ///
    /// `dataVersion` 只挂在 4 个 Service 的 `onDidCommit` 上；账户管理 / 分类管理是
    /// **直接拿 `writer` 改**的（`writer.insert/update/delete/save`），改完只调自己的
    /// `load()`，从不 `bumpDataVersion()`。
    ///
    /// 后果（用户可见）：在「账户」里把「微信」改名成「微信零钱」→ 返回账本，
    /// 列表里那一行的账户名仍是旧名 —— 因为 `EntryRowModel.accountName` 是
    /// `load()` 时拷贝下来的字符串快照，而首页只在 `dataVersion` 变化时重算。
    /// 名字要等到下一次记账 / 切月 / 重启 App 才会更新，用户会以为改名没生效。
    /// 分类改名同理（`categoryName` + 统计的分类占比）。
    func testR2_AccountRenameDoesNotBroadcastRefresh() throws {
        let world = try AcceptanceWorld.boot()
        let accountVM = AccountManageViewModel()
        accountVM.attach(world.env)
        let account = try world.firstAccount()

        let before = world.env.dataVersion
        try accountVM.update(
            id: account.id,
            name: "改过名字的账户",
            kind: .cash,
            initialBalanceCents: 0
        )

        XCTAssertGreaterThan(
            world.env.dataVersion, before,
            "改名后应广播一次 refresh，否则首页的 accountName 快照一直是旧名"
        )
        // 数据本身也是对的：改名确实落库了
        XCTAssertEqual(try world.firstAccount().name, "改过名字的账户")
    }

    // MARK: - R2b：改名的端到端断言（账本列表真的读到新名字）

    /// R2 只验了"有没有广播"；这条验**用户看到的结果**：
    /// 改名 → 首页按 `dataVersion` 重算 → 列表行的账户名是新名字。
    ///
    /// 为什么必须端到端再验一次：`dataVersion` 涨了不等于列表会变——
    /// 只要有人把 `EntryRowModel` 的 `accountName` 挪进缓存、或者首页的
    /// `.task(id: dataVersion)` 被误删，广播涨了照样显示旧名。
    /// 分类同理，这里用账户代表（两者走同一条 `finishWrite()`）。
    func testR2b_LedgerListShowsNewAccountNameAfterRename() throws {
        let world = try AcceptanceWorld.boot()
        let account = try world.firstAccount()
        let oldName = account.displayName

        let entryID = try world.manual(amount: 3_000, day: 20261120, note: "改名前的账目")

        let home = LedgerHomeViewModel(today: AcceptanceToday.value)
        home.attach(world.env)
        XCTAssertEqual(
            home.allGroups.first?.rows.first?.accountName, oldName,
            "前置条件：账本列表此刻显示的是旧账户名"
        )

        let accountVM = AccountManageViewModel()
        accountVM.attach(world.env)
        let before = world.env.dataVersion
        try accountVM.update(
            id: account.id,
            name: "微信零钱",
            kind: .cash,
            initialBalanceCents: 0
        )
        XCTAssertGreaterThan(world.env.dataVersion, before, "改名必须广播一次 refresh")

        // 模拟首页收到 `dataVersion` 变化后的重算（真实路径是 `.task(id:)` 触发）
        home.load()
        let row = try XCTUnwrap(home.allGroups.first?.rows.first)
        XCTAssertEqual(row.id, entryID, "前置条件：看的还是同一笔账")
        XCTAssertEqual(
            row.accountName, "微信零钱",
            "端到端：改名后账本列表必须显示新名字，否则用户会以为改名没生效"
        )
    }
}
