//
//  DebugDemoData.swift
//  一账 / App
//
//  职责：**只在 DEBUG** 下可用的演示数据注入，用于开发期与 QA 直接看到订阅页的真实布局。
//
//  为什么需要它（而不是"随手点几下就有了"）：
//  T13 之前没有任何"新建订阅"表单，订阅页在真机上永远是空态，
//  "总览卡会不会破版""时间轴折叠是否正确"这两件事就没有任何可视化验证手段——
//  而空态正常不等于总览卡正常。这个文件让订阅页的两种状态都能被截图检查。
//
//  三条纪律：
//  ① `#if DEBUG` 整体包裹，Release 构建里这些代码根本不存在；
//  ② 必须显式传启动参数才生效，正常 `Run` 不会塞任何假数据；
//  ③ 只在"一条订阅都没有"时注入，重复启动不会越积越多。
//
//  用法：
//  ```sh
//  xcrun simctl launch booted com.xiaoban.yizhang \
//      -YIZHANG_INITIAL_TAB subscription -YIZHANG_DEMO_SUBSCRIPTIONS 1
//  ```
//

#if DEBUG

import Foundation

/// 开发期演示数据。
@MainActor
enum DebugDemoData {

    /// 启动参数键：传 `1` / `YES` / `true` 生效。
    static let subscriptionFlagKey = "YIZHANG_DEMO_SUBSCRIPTIONS"

    /// 启动参数键：注入 10 笔手动账目（覆盖多天、多分类、多账户、含一笔转账与一笔收入）。
    static let entriesFlagKey = "YIZHANG_DEMO_ENTRIES"

    /// 若被要求且库里没有订阅，则插入 4 条覆盖三种状态的订阅，并跑一次结算扫描。
    ///
    /// - Parameters:
    ///   - subscription: 订阅服务（走真实业务路径，保证数据与线上结构一致）。
    ///   - sweep: 结算扫描（生成历史账目，让总览卡与时间轴都有内容）。
    ///   - writer: 只要用来判断"是否已有订阅"。
    static func seedSubscriptionsIfRequested(
        subscription: SubscriptionService,
        sweep: SweepCoordinator,
        writer: LedgerWriter
    ) {
        guard UserDefaults.standard.bool(forKey: subscriptionFlagKey) else { return }
        guard (try? writer.count(QueryDescriptors.allSubscriptions())) == 0 else { return }

        let today = DateOnly(Date())

        // 生效中、已扣了半年 → 总览卡的三个数字与时间轴都有内容
        _ = try? subscription.create(
            SubscriptionDraft(
                name: "视频会员",
                amount: 2500,
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.adding(months: -5).key
            ),
            today: today
        )

        // 年付、下次扣费在未来 → 只有 30 天窗口外的期数
        _ = try? subscription.create(
            SubscriptionDraft(
                name: "云盘",
                amount: 12000,
                cycleUnit: .year,
                cycleValue: 1,
                firstBillingDay: today.adding(months: 1).key
            ),
            today: today
        )

        // 不自动续费且已到期 → 行内出现「待续费」+「已续费」
        _ = try? subscription.create(
            SubscriptionDraft(
                name: "健身房月卡",
                amount: 19900,
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.adding(days: -3).key,
                autoRenew: false
            ),
            today: today
        )

        // 已暂停 → 第二个分组
        if let paused = try? subscription.create(
            SubscriptionDraft(
                name: "音乐会员",
                amount: 800,
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.adding(days: -10).key
            ),
            today: today
        ) {
            try? subscription.pause(id: paused.subscriptionID)
        }

        // 已取消 → 第三个分组（`nextBillingDay == 0`，行内显示「已取消」）
        if let cancelled = try? subscription.create(
            SubscriptionDraft(
                name: "旧报纸",
                amount: 1500,
                cycleUnit: .month,
                cycleValue: 1,
                firstBillingDay: today.adding(months: -2).key
            ),
            today: today
        ) {
            try? subscription.cancel(id: cancelled.subscriptionID)
        }

        // 生成历史账目（幂等：多跑几次也不会重复）
        _ = sweep.sweep(today: today, force: true)
    }

    // MARK: - 账目演示数据（T08 验收用）

    /// 若被要求且库里没有任何**手动**账目，则插入 11 笔覆盖多种日期/分类/账户的账目。
    ///
    /// 验收要求「用 DEBUG 演示数据造 8-10 笔不同日期、不同来源的账目，
    /// 核对分组头合计与概览卡数字」。这里的 11 笔是刻意设计的：
    /// - 支出 9 笔，合计 ¥2,960.50（分组头相加必须等于概览卡的支出）；
    /// - 收入 1 笔 ¥12,000.00（让「结余」不为零，能看出排版是否对齐）；
    /// - 含 **1 笔转账 ¥500.00**（转账既不进支出也不进收入——这是最容易算错的一条）；
    /// - 日期跨多天，且**夹在本月之内**（否则月初跑起来会串到上个月，分组数对不上）。
    ///
    /// - Parameters:
    ///   - ledger: 记账服务（走真实校验与写入路径）。
    ///   - writer: 用来判断"是否已有手动账目"。
    static func seedEntriesIfRequested(ledger: LedgerService, writer: LedgerWriter) {
        guard UserDefaults.standard.bool(forKey: entriesFlagKey) else { return }
        let existing = (try? writer.fetch(QueryDescriptors.entries(ofSource: .manual))) ?? []
        guard existing.isEmpty else { return }

        let today = DateOnly(Date())
        let monthStart = DateOnly(key: DateOnly.monthRange(today.monthKey).lowerBound)

        guard let expenseCategories = try? writer.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: false)
        ),
            let incomeCategories = try? writer.fetch(
                QueryDescriptors.categories(of: .income, includeHidden: false)
            ),
            let accounts = try? writer.fetch(QueryDescriptors.accounts(includeArchived: false)),
            !accounts.isEmpty
        else { return }

        let expenseByName = Dictionary(
            uniqueKeysWithValues: expenseCategories.map { ($0.name, $0.id) }
        )
        let incomeByName = Dictionary(
            uniqueKeysWithValues: incomeCategories.map { ($0.name, $0.id) }
        )
        let accountByName = Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, $0.id) })

        /// 一行演示数据。
        struct Plan {
            let daysAgo: Int
            let type: EntryType
            let amount: Int64
            let categoryName: String
            let accountName: String
            let note: String
            let toAccountName: String?
        }

        let plans: [Plan] = [
            Plan(daysAgo: 0, type: .expense, amount: 2800, categoryName: "餐饮",
                 accountName: "微信", note: "午饭", toAccountName: nil),
            Plan(daysAgo: 0, type: .expense, amount: 600, categoryName: "交通出行",
                 accountName: "支付宝", note: "地铁", toAccountName: nil),
            Plan(daysAgo: 1, type: .expense, amount: 8650, categoryName: "买菜生鲜",
                 accountName: "微信", note: "超市", toAccountName: nil),
            Plan(daysAgo: 2, type: .expense, amount: 12900, categoryName: "购物",
                 accountName: "信用卡", note: "运动鞋", toAccountName: nil),
            Plan(daysAgo: 3, type: .expense, amount: 3500, categoryName: "餐饮",
                 accountName: "微信", note: "请同事喝咖啡", toAccountName: nil),
            Plan(daysAgo: 5, type: .expense, amount: 250000, categoryName: "居住",
                 accountName: "储蓄卡", note: "房租", toAccountName: nil),
            Plan(daysAgo: 7, type: .expense, amount: 4500, categoryName: "娱乐",
                 accountName: "支付宝", note: "电影票", toAccountName: nil),
            Plan(daysAgo: 9, type: .expense, amount: 9900, categoryName: "通讯网络",
                 accountName: "微信", note: "话费", toAccountName: nil),
            Plan(daysAgo: 12, type: .income, amount: 1_200_000, categoryName: "工资",
                 accountName: "储蓄卡", note: "11 月工资", toAccountName: nil),
            Plan(daysAgo: 14, type: .expense, amount: 3200, categoryName: "医疗健康",
                 accountName: "现金", note: "感冒药", toAccountName: nil),
            Plan(daysAgo: 4, type: .transfer, amount: 50000, categoryName: "",
                 accountName: "支付宝", note: "转进储蓄卡", toAccountName: "储蓄卡")
        ]

        for plan in plans {
            // 夹在本月之内：月初跑起来时 `today - 14` 会落到上个月，那样分组数就对不上了
            let day = max(monthStart, today.adding(days: -plan.daysAgo))

            var draft = EntryDraft(
                typeRaw: plan.type.raw,
                amount: plan.amount,
                occurredDay: day.key
            )
            draft.note = plan.note
            draft.accountID = accountByName[plan.accountName]

            switch plan.type {
            case .expense:
                draft.categoryID = expenseByName[plan.categoryName]
            case .income:
                draft.categoryID = incomeByName[plan.categoryName]
            case .transfer:
                draft.categoryID = nil
                draft.toAccountID = plan.toAccountName.flatMap { accountByName[$0] }
            }

            _ = try? ledger.create(draft)
        }
    }
    // MARK: - 统计演示数据（T19 验收用）

    /// 启动参数键：注入 6 个月×多分类的账目，让三张图都有内容。
    static let statisticsFlagKey = "YIZHANG_DEMO_STATS"

    /// 若被要求且库里没有手动账目，则按"过去 6 个月"造 60 笔左右支出 + 6 笔收入。
    ///
    /// 刻意做成跨月、跨分类、金额有起伏：
    /// - 6 个月柱状图不能是一条平线（否则看不出"双柱并列"是不是真的）；
    /// - 分类要超过 8 个（否则验证不到「其他」合并）；
    /// - 上月同日要有数据（虚线才有得画），但上月天数少于本月时要留出缺口。
    ///
    /// - Parameters:
    ///   - ledger: 记账服务。
    ///   - writer: 用来判断"是否已有手动账目"。
    static func seedStatisticsIfRequested(ledger: LedgerService, writer: LedgerWriter) {
        guard UserDefaults.standard.bool(forKey: statisticsFlagKey) else { return }
        let existing = (try? writer.fetch(QueryDescriptors.entries(ofSource: .manual))) ?? []
        guard existing.isEmpty else { return }

        let today = DateOnly(Date())
        guard let categories = try? writer.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: false)
        ),
            let incomeCategories = try? writer.fetch(
                QueryDescriptors.categories(of: .income, includeHidden: false)
            ),
            let accounts = try? writer.fetch(QueryDescriptors.accounts(includeArchived: false)),
            !accounts.isEmpty, !categories.isEmpty
        else { return }

        let account = accounts[0].id

        // 每月一组：(分类下标, 金额分, 备注)
        let template: [(Int, Int64, String)] = [
            (0, 2800, "午饭"),
            (0, 4600, "晚饭"),
            (1, 600, "地铁"),
            (2, 8650, "超市"),
            (3, 12900, "日用品"),
            (4, 4500, "电影"),
            (5, 250000, "房租"),
            (6, 9900, "话费"),
            (7, 3200, "感冒药"),
            (8, 6800, "书")
        ]

        for monthOffset in 0..<6 {
            // 月内分布的日期：2、6、9、13、17、21 —— 上月只有 30 天时第 6 个点自然缺失
            let daysInThisMonth = [2, 6, 9, 13, 17, 21, 24, 27, 28, 30]

            for (index, item) in template.enumerated() {
                let dayOffset = daysInThisMonth[index % daysInThisMonth.count]
                guard let day = makeDay(
                    monthsAgo: monthOffset,
                    day: dayOffset,
                    today: today
                ) else { continue }

                // 金额按月轻微起伏：6 个月柱子不能一样高
                let variance = Int64((monthOffset % 3) * 800)
                var draft = EntryDraft(
                    typeRaw: EntryType.expense.raw,
                    amount: item.1 + variance,
                    occurredDay: day.key
                )
                draft.categoryID = categories[item.0 % categories.count].id
                draft.accountID = account
                draft.note = "\(item.2)\(monthOffset == 0 ? "" : "（\(monthOffset) 个月前）")"
                _ = try? ledger.create(draft)
            }

            // 每月一笔工资
            if let salaryDay = makeDay(monthsAgo: monthOffset, day: 10, today: today),
               let salaryCategory = incomeCategories.first {
                var draft = EntryDraft(
                    typeRaw: EntryType.income.raw,
                    amount: 1_200_000,
                    occurredDay: salaryDay.key
                )
                draft.categoryID = salaryCategory.id
                draft.accountID = account
                draft.note = "工资"
                _ = try? ledger.create(draft)
            }
        }
    }

    /// `monthsAgo` 个月前的第 `day` 天；那天不存在（如 2 月 30 日）时返回 nil。
    private static func makeDay(monthsAgo: Int, day: Int, today: DateOnly) -> DateOnly? {
        let monthKey = StatisticsCalculator.shiftMonth(today.monthKey, by: -monthsAgo)
        let year = Int(monthKey / 100)
        let month = Int(monthKey % 100)
        guard day <= DateOnly.daysInMonth(year: year, month: month) else { return nil }
        guard let candidate = DateOnly(year: year, month: month, day: day) else { return nil }
        // 当月不能造未来日期（会被 `LedgerService` 的校验挡掉）
        return candidate <= today ? candidate : nil
    }

    // MARK: - 通知权限演示（T20 截图用）

    /// 启动参数键：`-YIZHANG_DEMO_NOTIF denied` 把通知权限锁成"被拒"。
    ///
    /// 模拟器里没法真的在系统设置里关掉权限（`simctl privacy` 也没有通知这一项），
    /// 而"被拒后的设置页长什么样"正是 T20 必须截图自查的两件事之一
    /// （另一件是"关掉通知不影响记账"）。
    static let notificationFlagKey = "YIZHANG_DEMO_NOTIF"

    /// 若被要求，锁定通知权限状态（只影响 UI 文案，不参与任何业务判断）。
    static func applyNotificationOverrideIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: notificationFlagKey),
              let permission = NotificationPermission(rawValue: raw) else { return }
        NotificationService.permissionOverride = permission
    }

    // MARK: - 归档账户演示（T21 截图用）

    /// 启动参数键：把「微信」账户改成归档，用来截「已归档」标签那一行。
    static let archiveFlagKey = "YIZHANG_DEMO_ARCHIVE"

    /// 若被要求，归档一个有账目的账户（T21 需要证明归档标签与历史账目共存）。
    static func seedArchivedAccountIfRequested(writer: LedgerWriter) {
        guard UserDefaults.standard.bool(forKey: archiveFlagKey) else { return }
        guard let accounts = try? writer.fetch(QueryDescriptors.accounts()) else { return }
        // 挑名字最短的第二个账户：演示数据里它一定有几笔账，归档标签与余额能同屏看到
        guard let target = accounts.first(where: { $0.name.contains("微信") }) ?? accounts.dropFirst().first,
              !target.isArchived else { return }
        target.isArchived = true
        target.updatedAt = Date()
        try? writer.save()
    }

    // MARK: - 性能实测数据（T19 验收用）

    /// 启动参数键：注入 4000 条账目，用于统计页首帧耗时**实测**。
    ///
    /// 为什么要 4000 条而不是"感觉很快"：统计页的预算是「4000 条 < 80ms」，
    /// 这个数字只有把 4000 行真的塞进 SwiftData 再读一遍才有意义。
    static let performanceFlagKey = "YIZHANG_DEMO_PERF"

    /// 目标条数（架构给的压测规模）。
    static let performanceEntryTarget = 4000

    /// 压测条数可被启动参数覆盖：`-YIZHANG_DEMO_PERF_COUNT 10000`
    /// （T24 的冷启动 / 帧率预算按 **1 万条** 定的，不是 4000）。
    static var performanceEntryCount: Int {
        let raw = UserDefaults.standard.integer(forKey: "YIZHANG_DEMO_PERF_COUNT")
        return raw > 0 ? raw : performanceEntryTarget
    }

    /// 若被要求，则插入 4000 条分布在过去 12 个月的账目。
    ///
    /// 刻意跨 12 个月：6 个月柱状图要分桶、本年范围要跨月累计、趋势要分两个月的日。
    /// 插入用 `save: false` 批量 + 最后一次 `save()`，否则 4000 次事务会把启动拖到分钟级。
    static func seedPerformanceDataIfRequested(ledger: LedgerService, writer: LedgerWriter) {
        guard UserDefaults.standard.bool(forKey: performanceFlagKey) else { return }
        let target = performanceEntryCount
        let existing = (try? writer.count(QueryDescriptors.allEntries())) ?? 0
        guard existing < target else { return }

        let today = DateOnly(Date())
        guard let categories = try? writer.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: false)
        ),
            let accounts = try? writer.fetch(QueryDescriptors.accounts(includeArchived: false)),
            !categories.isEmpty, !accounts.isEmpty
        else { return }

        let accountID = accounts[0].id
        let started = CFAbsoluteTimeGetCurrent()
        var inserted = 0

        outer: for monthOffset in 0..<12 {
            let monthKey = StatisticsCalculator.shiftMonth(today.monthKey, by: -monthOffset)
            let year = Int(monthKey / 100)
            let month = Int(monthKey % 100)
            let daysInMonth = DateOnly.daysInMonth(year: year, month: month)

            for index in 0..<1_200 {
                let day = (index % daysInMonth) + 1
                guard let date = DateOnly(year: year, month: month, day: day), date <= today else {
                    continue
                }
                var draft = EntryDraft(
                    typeRaw: EntryType.expense.raw,
                    amount: Int64(100 + (index * 37) % 9000),
                    occurredDay: date.key
                )
                draft.categoryID = categories[index % categories.count].id
                draft.accountID = accountID
                draft.note = "perf-\(monthKey)-\(index)"
                _ = try? ledger.create(draft, save: false)
                inserted += 1
                if inserted >= target { break outer }
            }
        }

        try? writer.save()
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        PerfProbe.record(String(format: "[PERF] seeded %d entries in %.0fms", inserted, elapsed))
    }

    // MARK: - 待办演示数据（T15 / T16 验收用）

    /// 启动参数键：注入 2 条待办（一条带花销、一条不带）。
    static let todosFlagKey = "YIZHANG_DEMO_TODOS"

    /// 若被要求且库里没有待办，则插入一组覆盖五段分组的待办。
    ///
    /// 每条都在验一件事：
    /// - 「报销」`dueDay = 今天-2`、仍 open → **逾期归入「今天」并标红**；
    /// - 「买菜（待办）」`hasExpense` 完成 + 确认 → **两步完成**产出一笔 `source == .todo`
    ///   的账目（预计 48、实际 45，用来验证 R-TODO-6 在 UI 上分两行）；
    /// - 「取快递」`hasExpense == false` 完成 → **零打扰**、账目表零变化；
    /// - 「体检预约」今天 + 高优先级 → 今天分组里的优先级排序；
    /// - 「交电费」本周内 → 本周分组；
    /// - 「年度体检」较远 → 以后分组；
    /// - 「想看的书」无日期 → 无日期分组。
    ///
    /// - Parameter todo: 待办服务（走真实业务路径）。
    static func seedTodosIfRequested(todo: TodoService) {
        guard UserDefaults.standard.bool(forKey: todosFlagKey) else { return }
        guard (try? todo.todos().isEmpty) == true else { return }

        let today = DateOnly(Date())

        // 逾期（仍 open）：这一步是「逾期归入今天」的唯一可视化证据
        _ = try? todo.create(
            TodoDraft(
                title: "报销上个月的打车费",
                dueDay: today.adding(days: -2).key,
                priority: .high
            )
        )

        // 今天 + 高优先级
        _ = try? todo.create(
            TodoDraft(
                title: "体检预约",
                note: "问一下能不能改到周六",
                dueDay: today.key,
                dueTimeMinutes: 15 * 60,
                priority: .high
            )
        )

        // 本周
        _ = try? todo.create(
            TodoDraft(
                title: "交电费",
                dueDay: today.adding(days: 3).key,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 12000
            )
        )

        // 以后
        _ = try? todo.create(
            TodoDraft(title: "年度体检", dueDay: today.adding(days: 20).key)
        )

        // 无日期
        _ = try? todo.create(TodoDraft(title: "想看的书：《长安的荔枝》"))

        // 已完成 + 有花销：走完两步，产出一笔 todo 来源的账目
        if let id = try? todo.create(
            TodoDraft(
                title: "买菜（待办）",
                note: "顺路把牛奶带上",
                dueDay: today.key,
                dueTimeMinutes: 18 * 60,
                hasExpense: true,
                hasEstimatedAmount: true,
                estimatedAmount: 4800,
                reminderDay: today.key,
                reminderMinutes: 9 * 60
            )
        ), let request = try? todo.complete(id: id) {
            _ = try? todo.confirmCompletion(
                CompletionConfirmation(amountCents: 4500),
                for: request
            )
        }

        // 已完成 + 无花销：完成即结束，不产生账目
        if let id = try? todo.create(
            TodoDraft(
                title: "取快递",
                dueDay: today.key,
                dueTimeMinutes: 20 * 60,
                hasExpense: false
            )
        ) {
            _ = try? todo.complete(id: id)
        }
    }
}

#endif
