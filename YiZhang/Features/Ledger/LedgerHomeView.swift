//
//  LedgerHomeView.swift
//  一账 / Features / Ledger
//
//  职责：账本首页（T08）——月份切换 + 月度概览卡 + 今日速览 + 按日分组列表 + FAB + 筛选 chips。
//
//  这一屏是产品主体（用户 90% 的时间在这里），因此几个细节是刻意的：
//  ① **大标题换成 inline + 中间月份切换器**：大标题会把「2026年11月」和「筛选/统计」挤到两行，
//     中间空出一大片（订阅页踩过这个坑）。年份月份是本页最重要的上下文，它必须一直在。
//  ② **概览卡的数字与分组头的合计来自同一批数据**（`LedgerHomeViewModel.summarize` /
//     `DayGroup.make`），所以"卡上的支出"永远等于"分组头合计之和"——这是本批的验收项。
//  ③ **保存后顶部插入 + 0.2s 高亮 + 3 秒撤销**：列表在顶部插入新行时，用户视线还停在 FAB 上，
//     没有高亮就等于"点了保存但什么都没发生"。
//  ④ **两种空态分开**：「这个月还没有记录」（真没数据）与「没有符合条件的账目」（筛没了），
//     用同一句话会让用户去怀疑数据丢了。
//
//  本页不写任何业务判断：金额校验在 `EntryViewModel`，分组/汇总裁在 `LedgerHomeViewModel`。
//

import SwiftUI

/// 账本首页。
struct LedgerHomeView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = LedgerHomeViewModel()
    @State private var entrySheet: EntrySheetTarget?
    @State private var toast: ToastItem?
    @State private var highlightedEntryID: UUID?
    @State private var showsFilterSheet = false
    @State private var detailEntryID: UUID?

    var body: some View {
        // `ScrollViewReader` 本身是零成本容器，Release 里不会带来任何额外开销；
        // 它在这里的唯一用途是让 DEBUG 性能探针能程序化地滚动列表（模拟器没有脚本化滑动）。
        ScrollViewReader { proxy in
            scrollBody(proxy: proxy)
        }
    }

    @ViewBuilder
    private func scrollBody(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let errorMessage = viewModel.errorMessage {
                    errorRow(message: errorMessage)
                }

                MonthOverviewCard(
                    summary: viewModel.overview,
                    comparison: viewModel.comparison,
                    monthTitle: viewModel.monthTitle,
                    onTap: { statisticsTarget = true }
                )
                .padding(.horizontal, Theme.Spacing.md)

                TodayGlanceStrip(
                    glance: viewModel.glance,
                    onTapTodo: nil,
                    onTapSubscription: nil
                )
                .padding(.horizontal, Theme.Spacing.md)

                if viewModel.isFiltering {
                    filterChipBar
                }

                content

                if viewModel.hasAnyEntry {
                    // 底部留白：最后一行不要贴着 Tab bar
                    Color.clear.frame(height: Theme.Spacing.xl)
                }
            }
            .padding(.top, Theme.Spacing.xs)
            .padding(.bottom, Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Semantic.pageBackground)
        .navigationTitle("账本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                monthSwitcher
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsFilterSheet = true
                } label: {
                    Image(systemName: viewModel.isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                }
                .accessibilityLabel(Text(viewModel.isFiltering ? "筛选，已启用" : "筛选"))
                .accessibilityIdentifier("ledger.filter")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            floatingAddButton
        }
        .navigationDestination(isPresented: $statisticsTarget) {
            StatisticsView { monthKey in
                // 统计页点了某个月 → 回到本页并切到那个月（保持当前筛选条件不变）
                statisticsTarget = false
                viewModel.goToMonth(monthKey)
            }
        }
        .navigationDestination(item: $detailEntryID) { entryID in
            EntryDetailView(entryID: entryID)
        }
        .task {
            viewModel.attach(environment)
            openDemoScreenIfRequested()
        }
        .task(id: environment.dataVersion) {
            // dataVersion 是全局写入广播：任何写入提交后自增，本页据此重算
            viewModel.load()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(item: $entrySheet) { target in
            EntrySheetView(editing: target.snapshot, today: viewModel.today) { result in
                handleSaved(result)
            }
            .environment(environment)
            .modelContainer(environment.container)
        }
        .sheet(isPresented: $showsFilterSheet) {
            EntryFilterSheet(
                filter: viewModel.filter,
                categories: viewModel.categoryOptions,
                accounts: viewModel.accountOptions,
                today: viewModel.today
            ) { newFilter in
                viewModel.applyFilter(newFilter)
            }
        }
        .toast(item: $toast)
        .accessibilityIdentifier("ledger.home")
        #if DEBUG
        .task {
            await PerfProbe.driveScrollIfRequested(
                proxy: proxy,
                groupIDs: viewModel.groups.map { AnyHashable($0.id) }
            )
        }
        #endif
    }

    /// 统计页跳转（T19 占位）。
    @State private var statisticsTarget = false

    // MARK: - 月份切换器

    private var monthSwitcher: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Button {
                viewModel.goPreviousMonth()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("上一月"))
            .accessibilityIdentifier("ledger.previousMonth")

            Button {
                viewModel.goToCurrentMonth()
            } label: {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text(viewModel.monthTitle)
                        .font(Theme.Typography.headline)
                        .monospacedDigit()
                        // AX 字号下导航栏标题会截成「2026 年…」：允许缩到 0.5 倍也不省略
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !viewModel.isCurrentMonth {
                        Text("回到本月")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Theme.minimumTapSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(viewModel.monthTitle)，轻点回到本月"))
            .accessibilityIdentifier("ledger.monthTitle")

            Button {
                viewModel.goNextMonth()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                    .contentShape(Rectangle())
            }
            .disabled(!viewModel.canGoNextMonth)
            .accessibilityLabel(Text("下一月"))
            .accessibilityIdentifier("ledger.nextMonth")
        }
    }

    // MARK: - 列表内容

    @ViewBuilder
    private var content: some View {
        // 顺序有意义：先判"筛选后为空"——此时 `hasAnyEntry` 仍为真，
        // 若先判 `hasAnyEntry` 就会渲染一个空 ForEach，用户看到一片空白。
        if viewModel.isFilteredEmpty {
            filteredEmptyBlock
        } else if viewModel.hasAnyEntry {
            ForEach(viewModel.groups) { group in
                groupBlock(group)
            }
        } else {
            emptyBlock
        }
    }

    private func groupBlock(_ group: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderView(title: group.headerTitle, detail: group.detailText)

            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        detailEntryID = row.id
                    } label: {
                        EntryRowView(row: row, isHighlighted: row.id == highlightedEntryID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("轻点查看详情"))

                    if index < group.rows.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .padding(.leading, Theme.Spacing.md + CategoryGlyph.Size.medium.side + Theme.Spacing.sm)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Semantic.cardBackground)
            )
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    // MARK: - 筛选 chips

    private var filterChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(viewModel.filterChips) { chip in
                    Button {
                        viewModel.removeChip(id: chip.id)
                    } label: {
                        HStack(spacing: 2) {
                            Text(chip.title)
                                .font(Theme.Typography.captionStrong)
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .frame(height: 28)
                        .background(Capsule(style: .continuous).fill(Theme.Semantic.cardBackground))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Theme.minimumTapSize)
                    .accessibilityLabel(Text("移除筛选 \(chip.title)"))
                }

                Button {
                    viewModel.clearFilter()
                } label: {
                    Text("清除全部")
                        .font(Theme.Typography.captionStrong)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: Theme.minimumTapSize)
                .accessibilityIdentifier("ledger.clearFilter")
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .accessibilityIdentifier("ledger.filterChips")
    }

    // MARK: - 空态

    private var emptyBlock: some View {
        EmptyStateView(
            iconName: "list.bullet.rectangle",
            title: "这个月还没有记录",
            message: "点右下角的 + 记下第一笔。今天花了多少，一眼就能看见。",
            actionTitle: "记一笔",
            action: { entrySheet = .new }
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var filteredEmptyBlock: some View {
        EmptyStateView(
            iconName: "line.3.horizontal.decrease.circle",
            title: "没有符合条件的账目",
            message: "这个月有 \(viewModel.entryCount) 笔账，但都不满足当前的筛选条件。",
            actionTitle: "清除筛选",
            action: { viewModel.clearFilter() }
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - FAB

    private var floatingAddButton: some View {
        Button {
            entrySheet = .new
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
        }
        .accessibilityLabel(Text("记一笔"))
        .accessibilityIdentifier("ledger.add")
        .padding(.trailing, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: - 保存后

    /// 保存成功后：跳到那笔账所在的月份 → 高亮 → Toast + 撤销。
    private func handleSaved(_ result: EntrySaveResult) {
        if result.day.monthKey != viewModel.monthKey {
            viewModel.goToMonth(result.day.monthKey)
        } else {
            viewModel.load()
        }

        flashHighlight(result.id)

        guard !result.isEdit else {
            toast = ToastItem(message: result.message)
            return
        }

        toast = ToastItem(message: result.message, actionTitle: "撤销") { [id = result.id] in
            Task {
                _ = await environment.ledger.delete(id: id)
            }
        }
    }

    /// 让新插入的那一行亮 0.2s。
    ///
    /// 用 `Task.sleep` 而不是 `withAnimation` 自带时长：高亮的"亮起"是立刻的，
    /// 只有"熄灭"需要延时，否则用户会看到底色慢慢浮上来，反而注意不到行插入。
    private func flashHighlight(_ id: UUID) {
        highlightedEntryID = id
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if highlightedEntryID == id {
                highlightedEntryID = nil
            }
        }
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

    // MARK: - 开发期直达（仅 DEBUG）

    /// 只服务开发/QA：按启动参数直接打开「记账 Sheet」或「第一笔账的详情」，
    /// 让三张验收截图可以在无头模拟器上取到（无法合成点击手势）。
    ///
    /// ```sh
    /// xcrun simctl launch booted com.xiaoban.yizhang -YIZHANG_DEMO_ENTRIES 1 -YIZHANG_DEMO_OPEN entry
    /// ```
    /// Release 构建里整段被 `#if DEBUG` 摘掉，恒为 no-op。
    private func openDemoScreenIfRequested() {
        #if DEBUG
        guard let target = UserDefaults.standard.string(forKey: "YIZHANG_DEMO_OPEN") else { return }
        switch target {
        case "entry":
            entrySheet = .new
        case "detail":
            if let id = viewModel.allGroups.first?.rows.first?.id {
                detailEntryID = id
            }
        case "filter":
            // 筛选面板（截图用）：面板自身是 `.sheet`，无法靠点击合成打开
            showsFilterSheet = true
        case "stats", "stats-tooltip", "stats-lower", "stats-drill":
            // 统计页（截图 / 性能实测用）：统计页是 push 出来的，合成不了点击
            statisticsTarget = true
        case "chips":
            // 带筛选条件的首页（截图用）：预置三个维度的条件，验证 chips 行的排版与换行
            var demo = viewModel.filter
            demo.time = .monthToDate
            demo.types = [.expense]
            if let catering = viewModel.categoryOptions.first(where: { $0.name == "餐饮" }) {
                demo.categoryIDs = [catering.id]
            }
            viewModel.applyFilter(demo)
        case "filtered-empty":
            // 筛选后为空（截图用）：关键词一定匹配不到任何备注。
            // 这条空态和「这个月还没有记录」是两回事，必须分别看一遍。
            var demo = viewModel.filter
            demo.keyword = "zzz-不存在的备注-zzz"
            viewModel.applyFilter(demo)
        default:
            break
        }
        #endif
    }
}

// MARK: - Sheet 目标

/// 记账 Sheet 的目标。
///
/// 目前只有「新建」：编辑走详情页自己的 Sheet（`EntryDetailView`），
/// 因为编辑是"针对那一笔账"的动作，从详情页发起比从首页发起更符合预期。
/// 用 `Identifiable` 而不是 `Bool`，是为了和 `.sheet(item:)` 的重建语义保持一致
/// （`Bool` 在某些情况下会复用上一次的内容）。
private enum EntrySheetTarget: Identifiable {
    case new

    var id: String { "new" }

    /// 编辑模式的快照；首页恒为 nil。
    var snapshot: LedgerEntrySnapshot? { nil }
}

// MARK: - 预览

#Preview("账本首页") {
    LedgerHomePreview()
}

private struct LedgerHomePreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            NavigationStack {
                LedgerHomeView()
            }
            .environment(environment)
            .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
        }
    }
}
