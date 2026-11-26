//
//  StatisticsView.swift
//  一账 / Features / Statistics
//
//  职责：统计页（T19 P0）——顶部范围切换 + 三张图 + 分类排行。
//
//  ## 四条刻意的设计
//
//  ① **顶部只有三档范围（本月/上月/本年），右上角不放「⋯」**：统计页的"更多功能"
//     是典型的找不到入口又想放的功能区。P0 只把三张图做对。
//  ② **点柱状图不硬跳**：`onSelectMonth` 是个回调，由上层决定怎么跳（这里弹一个
//     确认式跳转提示）。图表组件不该知道"账本页"的存在。
//  ③ **每张图都有等价的文字结论**（`.accessibilityLabel`），并且这句结论与
//     视力正常用户看到的是同一件事——图只是它的可视化。
//  ④ **空态不画坐标系**（见 `StatisticsEmptyStates`）。
//

import SwiftUI

/// 统计页。
struct StatisticsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = StatisticsViewModel()
    /// 柱状图点击后要跳的月份（用于给出"去账本看看"的动作）。
    @State private var pendingMonthJump: Int32?
    /// 分类下钻目标。
    @State private var drillTarget: DrillTarget?
    /// DEBUG 截图用：需要把页面滚到哪一张卡片（`ScrollViewReader` 的锚点）。
    @State private var demoScrollAnchor: String?

    /// AX 字号下需要改布局（两张合计卡上下排、图表换成文字结论）。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 由上层注入：点某个 → 切到该月账本。默认什么都不做（预览/测试安全）。
    var onSelectMonth: ((Int32) -> Void)?

    init(onSelectMonth: ((Int32) -> Void)? = nil) {
        self.onSelectMonth = onSelectMonth
    }

    var body: some View {
        ScrollViewReader { proxy in
            statisticsScroll
                .task(id: demoScrollAnchor) {
                    guard let anchor = demoScrollAnchor else { return }
                    // 等首帧画完再滚，否则 ScrollView 还没有内容高度，滚不动
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                }
        }
    }

    private var statisticsScroll: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.md) {
                rangePicker

                if let errorMessage = viewModel.errorMessage {
                    errorRow(message: errorMessage)
                }

                totalsRow

                StatsCard(
                    title: "近 6 个月收支",
                    subtitle: "点某个月可以跳到那个月的账本",
                    isEmpty: viewModel.snapshot.monthlySeries.allSatisfy {
                        $0.expense.cents == 0 && $0.income.cents == 0
                    },
                    emptyMessage: StatisticsEmptyCopy.monthly,
                    emptyIcon: "chart.bar"
                ) {
                    if dynamicTypeSize.isAccessibilitySize {
                        // AX 字号下柱子图的坐标轴会叠字，直接给结论（T24 截图实测）
                        ChartAccessibilityFallback(
                            summary: viewModel.monthlyComparisonSummary,
                            hint: "想看每个月具体数字，可以到账本里逐月查看。"
                        )
                    } else {
                        MonthlyFlowChart(
                            series: viewModel.snapshot.monthlySeries,
                            summary: viewModel.monthlyComparisonSummary
                        ) { monthKey in
                            // 不直接跳：先让用户确认（图表是最容易误触的区域）
                            pendingMonthJump = monthKey
                        }
                    }
                }

                StatsCard(
                    title: "\(viewModel.metric.displayName)分类占比",
                    subtitle: viewModel.rangeTitle,
                    isEmpty: viewModel.snapshot.categoryShares.isEmpty,
                    emptyMessage: StatisticsEmptyCopy.category(
                        rangeTitle: viewModel.rangeTitle,
                        metric: viewModel.metric
                    ),
                    emptyIcon: "chart.pie"
                ) {
                    VStack(spacing: Theme.Spacing.sm) {
                        if dynamicTypeSize.isAccessibilitySize {
                            ChartAccessibilityFallback(
                                summary: viewModel.categorySummary,
                                hint: "下面的排行里可以看到每个分类的金额与占比。"
                            )
                        } else {
                            CategoryShareChart(
                                shares: viewModel.snapshot.categoryShares,
                                total: viewModel.snapshot.categoryTotal,
                                totalTitle: "\(viewModel.metric.displayName)合计",
                                title: { viewModel.title(for: $0) },
                                colorHex: { viewModel.colorHex(for: $0) },
                                summary: viewModel.categorySummary
                            ) { share in
                                drillTarget = .category(share)
                            }
                        }

                        CategoryRankingView(
                            shares: viewModel.snapshot.categoryShares,
                            title: { viewModel.title(for: $0) },
                            iconName: { viewModel.iconName(for: $0) },
                            colorHex: { viewModel.colorHex(for: $0) }
                        ) { share in
                            drillTarget = .category(share)
                        }
                        .padding(.horizontal, -Theme.Spacing.md)
                    }
                }
                .id("category")

                StatsCard(
                    title: "本月累计\(viewModel.metric.displayName)",
                    subtitle: "实线本月 · 虚线上月同期",
                    isEmpty: !viewModel.snapshot.hasMetricData,
                    emptyMessage: StatisticsEmptyCopy.trend(metric: viewModel.metric),
                    emptyIcon: "chart.line.uptrend.xyaxis"
                ) {
                    if dynamicTypeSize.isAccessibilitySize {
                        ChartAccessibilityFallback(summary: viewModel.trendSummary)
                    } else {
                        CumulativeTrendChart(
                            points: viewModel.snapshot.trend,
                            today: viewModel.today,
                            summary: viewModel.trendSummary,
                            selectedDay: $viewModel.selectedDay
                        )
                    }
                }
                .id("trend")

                StatsCard(
                    title: "\(viewModel.metric.displayName)同比环比",
                    subtitle: viewModel.comparisonSubtitle,
                    isEmpty: viewModel.isComparisonEmpty,
                    emptyMessage: StatisticsEmptyCopy.comparison(
                        rangeTitle: viewModel.rangeTitle,
                        metric: viewModel.metric
                    ),
                    emptyIcon: "arrow.up.arrow.down"
                ) {
                    ComparisonCardContent(
                        comparison: viewModel.comparison,
                        bounds: viewModel.comparisonBounds,
                        range: viewModel.range,
                        metric: viewModel.metric,
                        today: viewModel.today
                    )
                }
                .id("comparison")

                StatsCard(
                    title: "\(viewModel.metric.displayName)账户构成",
                    subtitle: viewModel.rangeTitle,
                    isEmpty: viewModel.accountShares.isEmpty,
                    emptyMessage: StatisticsEmptyCopy.accountShares(
                        rangeTitle: viewModel.rangeTitle,
                        metric: viewModel.metric
                    ),
                    emptyIcon: "creditcard"
                ) {
                    AccountShareCardContent(
                        shares: viewModel.accountShares,
                        metric: viewModel.metric,
                        title: { viewModel.title(for: $0) },
                        isArchived: { viewModel.isArchived($0) },
                        canDrill: { viewModel.canDrill(into: $0) }
                    ) { share in
                        drillTarget = .account(share)
                    }
                }
                .id("accounts")

                Color.clear.frame(height: Theme.Spacing.md)
            }
            .padding(.top, Theme.Spacing.sm)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Semantic.pageBackground)
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.attach(environment)
            applyDemoStateIfRequested()
        }
        .task(id: environment.dataVersion) {
            let started = CFAbsoluteTimeGetCurrent()
            viewModel.reload()
            logFirstFrameIfRequested(since: started)
        }
        .refreshable {
            await viewModel.refresh()
        }
        .navigationDestination(item: $drillTarget) { target in
            switch target.kind {
            case let .category(share):
                CategoryEntriesView(
                    categoryTitle: viewModel.title(for: share),
                    range: viewModel.range,
                    today: viewModel.today,
                    categoryID: share.categoryID,
                    isMerged: share.isMerged,
                    mergedCategoryIDs: viewModel.snapshot.mergedCategoryIDs
                )
            case let .account(share):
                AccountEntriesView(
                    accountTitle: viewModel.title(for: share),
                    range: viewModel.range,
                    today: viewModel.today,
                    metric: viewModel.metric,
                    accountIDs: viewModel.drillAccountIDs(for: share),
                    isMerged: share.isMerged
                )
            }
        }
        .confirmationDialog(
            "跳到那个月的账本？",
            isPresented: Binding(
                get: { pendingMonthJump != nil },
                set: { if !$0 { pendingMonthJump = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMonthJump
        ) { monthKey in
            Button("去 \(monthKey / 100) 年 \(monthKey % 100) 月") {
                onSelectMonth?(monthKey)
                pendingMonthJump = nil
            }
            Button("留在这里", role: .cancel) { pendingMonthJump = nil }
        } message: { _ in
            Text("会把账本页切到那个月，筛选条件保持不变。")
        }
        .accessibilityIdentifier("stats.root")
    }

    // MARK: - 顶部

    private var rangePicker: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Picker("口径", selection: Binding(
                get: { viewModel.metric },
                set: { viewModel.metric = $0 }
            )) {
                ForEach(StatisticsMetric.allCases, id: \.self) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("stats.metric")

            Picker("范围", selection: Binding(
                get: { viewModel.range },
                set: { viewModel.range = $0 }
            )) {
                ForEach(StatisticsRange.allCases, id: \.self) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("stats.range")

            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.rangeTitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Spacing.xs)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// 支出 / 收入两个大数字（当前范围）。
    private var totalsRow: some View {
        // AX 字号下两张卡并排会让「¥37696.00」被压成「¥3769…」（T24 截图实测），
        // 无障碍字号时上下排、各占满宽。
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Theme.Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.sm))

        return layout {
            totalCard(
                title: "支出",
                amount: viewModel.snapshot.totalExpense,
                color: Theme.Semantic.expense
            )
            totalCard(
                title: "收入",
                amount: viewModel.snapshot.totalIncome,
                color: Theme.Semantic.income
            )
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func totalCard(title: String, amount: Money, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            Text(amount.formatted())
                .font(Theme.Typography.amountMedium)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title) \(amount.formatted())"))
    }

    private func errorRow(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Semantic.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.xs)
            Button("知道了") { viewModel.dismissError() }
                .font(Theme.Typography.captionStrong)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - DEBUG 性能埋点

    /// 4000 条账目首帧耗时的**实测**（`-YIZHANG_DEMO_PERF 1` 时生效）。
    ///
    /// 口径（写清楚，避免拿一个好看的数字自欺）：
    /// - `t0` = 本页 `.task` 开始（此时数据还没取）；
    /// - `fetch` = SwiftData 取全表 + 映射成 `LedgerLite`；
    /// - `aggregate` = `StatisticsCalculator.snapshot` 的全部聚合；
    /// - `firstFrame` = 状态装载完成后再过一个主队列回合（即渲染周期开始前），
    ///   也就是"用户能看见第一帧"的**上界**。
    private func logFirstFrameIfRequested(since started: CFAbsoluteTime) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: DebugDemoData.performanceFlagKey) else { return }
        DispatchQueue.main.async {
            let total = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print(String(
                format: "[PERF] cold entries=%d fetch=%.1fms aggregate=%.1fms reload=%.1fms firstFrame=%.1fms",
                viewModel.loadedEntryCount,
                viewModel.lastFetchMilliseconds,
                viewModel.lastAggregateMilliseconds,
                viewModel.lastLoadMilliseconds,
                total
            ))

            // 再连跑 3 次，给出**稳态**数字。
            // 冷启动那一发里混着 Swift Charts 框架初始化、字体加载、SwiftData store 首次打开，
            // 把它当"统计页性能"会高估一个量级；用户日常感知的是这里的数字。
            Task { @MainActor in
                for index in 1...3 {
                    let tick = CFAbsoluteTimeGetCurrent()
                    viewModel.reload()
                    // 只量"取数 + 聚合 + 状态装载"；下面那次 sleep 是等一帧真的画出来，
                    // **不计入数字**（否则会把故意的等待算成性能差）。
                    let milliseconds = (CFAbsoluteTimeGetCurrent() - tick) * 1000
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    print(String(
                        format: "[PERF] warm#%d entries=%d fetch=%.1fms aggregate=%.1fms reload=%.1fms",
                        index,
                        viewModel.loadedEntryCount,
                        viewModel.lastFetchMilliseconds,
                        viewModel.lastAggregateMilliseconds,
                        milliseconds
                    ))
                }
                print("[PERF] done")
            }
        }
        #endif
    }

    // MARK: - DEBUG 截图钩子

    /// `-YIZHANG_DEMO_OPEN stats` / `stats-tooltip`：
    /// 无头截图时无法合成手势，所以用启动参数把页面直接推到目标状态。
    private func applyDemoStateIfRequested() {
        #if DEBUG
        // 口径切换（截图用）：单独一个键，这样"打开统计页"和"切到收入"能自由组合
        if let raw = UserDefaults.standard.string(forKey: "YIZHANG_DEMO_METRIC"),
           let metric = StatisticsMetric(rawValue: raw) {
            viewModel.metric = metric
        }
        guard let target = UserDefaults.standard.string(forKey: "YIZHANG_DEMO_OPEN") else { return }
        switch target {
        case "stats-tooltip":
            viewModel.selectedDay = 18
            demoScrollAnchor = "trend"
        case "stats-lower":
            demoScrollAnchor = "category"
        case "stats-comparison":
            demoScrollAnchor = "comparison"
        case "stats-accounts":
            demoScrollAnchor = "accounts"
        case "stats-account-drill":
            // 账户构成的下钻同样是 pushed 页面，合成不了点击
            Task { @MainActor in
                await Task.yield()
                if let top = viewModel.accountShares.first(where: { viewModel.canDrill(into: $0) }) {
                    drillTarget = .account(top)
                }
            }
        case "stats-drill":
            // 下钻是 pushed 页面，同样合成不了点击；等一拍让首帧先画完再 push
            Task { @MainActor in
                await Task.yield()
                if let top = viewModel.snapshot.categoryShares.first {
                    drillTarget = .category(top)
                }
            }
        case "stats":
            break
        default:
            break
        }
        #endif
    }
}

// MARK: - 下钻目标

/// 下钻的导航目标。
///
/// 为什么把两种下钻合成**一个** item 而不是加第二个 `.navigationDestination(item:)`：
/// 同一层视图上叠两个 `item:` 版本的 destination，二者的注册顺序在 SwiftUI 里没有保证，
/// 表现是"点分类偶尔没反应"。合成一个枚举后只有一个 destination、只有一条 push 路径，
/// 同时把"分类 / 账户"的互斥关系写进了类型。
private struct DrillTarget: Identifiable, Hashable {

    enum Kind: Hashable {
        case category(CategoryShare)
        case account(AccountShare)
    }

    let id = UUID()
    let kind: Kind

    static func category(_ share: CategoryShare) -> DrillTarget {
        DrillTarget(kind: .category(share))
    }

    static func account(_ share: AccountShare) -> DrillTarget {
        DrillTarget(kind: .account(share))
    }
}

// MARK: - 预览

#Preview("统计") {
    StatisticsPreview()
}

private struct StatisticsPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            NavigationStack {
                StatisticsView()
            }
            .environment(environment)
            .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
                .foregroundStyle(.secondary)
        }
    }
}
