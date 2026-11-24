//
//  SubscriptionListView.swift
//  一账 / Features / Subscription
//
//  职责：订阅页（PRD 4.5）——顶部总览卡 + 可折叠的 30 天时间轴 + 三组列表 + 行内动作。
//
//  **为什么从 `List` 改成 `ScrollView + LazyVStack`**（这一版的核心改动）：
//  `List` 会给每个 `Section` 前后各加一段系统间距，且 `listSectionSpacing(.compact)` /
//  `defaultMinListHeaderHeight = 0` 都消不掉总览卡与第一个分组头之间那 ~50pt 的空白
//  （实测三次都没消掉）。而总览卡、时间轴本来就是自绘卡片，混在 `List` 里只会一直打架。
//  改成 `ScrollView + LazyVStack` 后，纵向节奏完全由 `Theme.Spacing` 决定：
//  12pt 分组间距 = 代码里写的 12pt，不再有"看不见的 44pt"。
//
//  `List` 一走，`.swipeActions` 也就没了（它只在 `List` 里生效）。
//  替代方案是 `.contextMenu`（长按）：这不是降级——`.swipeActions` 在 VoiceOver 里本来就
//  藏在"操作"转子里，而 `contextMenu` 是系统一等公民，`accessibilityAction` 自动可达。
//  页面底部给一句「长按订阅可以暂停或删除」提示，补上可发现性。
//
//  三条交互约定：
//  ① 进页面自动扫一次（R-SUB-2），受 `SweepCoordinator` 的 60s 节流保护；
//     下拉刷新是**用户显式意图**，用 `force: true` 绕过节流。
//  ② 「+」与整行点击都进同一个 `SubscriptionEditorView`（T13）：`.create` / `.edit(id)`。
//  ③ 删除有二次确认：删订阅会丢掉"取消但保留总览"的可能性（E-11 建议优先取消）。
//

import SwiftUI

/// 订阅列表页。
struct SubscriptionListView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = SubscriptionListViewModel()
    @State private var toast: ToastItem?
    @State private var editorTarget: SubscriptionEditorTarget?
    @State private var deletionTarget: SubscriptionListViewModel.RowModel?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let errorMessage = viewModel.errorMessage {
                    errorRow(message: errorMessage)
                }

                if viewModel.overview.hasData {
                    overviewBlock
                }

                if viewModel.groups.isEmpty {
                    emptyBlock
                } else {
                    ForEach(viewModel.groups) { group in
                        groupBlock(group)
                    }
                    hintRow
                }
            }
            .padding(.top, Theme.Spacing.xs)
            // 底部留白：Tab bar 之上不再压住最后一行（原来的 `List` 会把最后一行顶到
            // Tab bar 底下，滚到底也看不全）
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Semantic.pageBackground)
        .navigationTitle("订阅")
        // inline：大标题模式会把「订阅」和右上角「+」分成两行，中间空出一大片；
        // inline 让标题与「+」同处一行，纵向空间全给内容。
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = SubscriptionEditorTarget(mode: .create)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                }
                .accessibilityLabel(Text("新建订阅"))
                .accessibilityIdentifier("subscription.add")
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            viewModel.attach(environment)
            await viewModel.refresh()
            openDemoEditorIfRequested()
        }
        .task(id: environment.dataVersion) {
            viewModel.load(today: viewModel.today)
        }
        .toast(item: $toast)
        .sheet(item: $editorTarget) { target in
            SubscriptionEditorView(mode: target.mode, today: viewModel.today) { message in
                guard let message else { return }
                toast = ToastItem(message: message)
            }
        }
        .confirmationDialog(
            "删除订阅？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { row in
            Button("删除", role: .destructive) {
                if let message = viewModel.delete(row) {
                    toast = ToastItem(message: message)
                }
                deletionTarget = nil
            }
            Button("取消", role: .cancel) {
                deletionTarget = nil
            }
        } message: { row in
            Text("「\(row.name)」会被移除，已经生成的账目会保留。如果只是想停掉自动记账，选「暂停」更好。")
        }
        .accessibilityIdentifier("subscription.list")
    }

    /// 让编辑页能在无头模拟器上被截图（无法合成点击手势）。
    ///
    /// ```sh
    /// xcrun simctl launch booted com.xiaoban.yizhang \
    ///     -YIZHANG_INITIAL_TAB subscription -YIZHANG_DEMO_SUBSCRIPTIONS 1 \
    ///     -YIZHANG_DEMO_OPEN subscription-editor
    /// ```
    /// Release 构建里整段被 `#if DEBUG` 摘掉，恒为 no-op。
    private func openDemoEditorIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.string(forKey: "YIZHANG_DEMO_OPEN") == "subscription-editor" else {
            return
        }
        editorTarget = SubscriptionEditorTarget(mode: .create)
        #endif
    }

    // MARK: - 顶部：总览 + 时间轴

    private var overviewBlock: some View {
        VStack(spacing: Theme.Spacing.sm) {
            SubscriptionOverviewCard(overview: viewModel.overview)

            if !viewModel.overview.upcoming.isEmpty || viewModel.isTimelineExpanded {
                SubscriptionTimelineCard(
                    items: viewModel.overview.upcoming,
                    total: viewModel.overview.upcomingTotal,
                    today: viewModel.today,
                    isExpanded: $viewModel.isTimelineExpanded
                )
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - 分组列表

    private func groupBlock(_ group: SubscriptionListViewModel.GroupModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 分组头：`SectionHeaderView` 自带 16pt 左右内边距，与下方卡片左缘对齐
            SectionHeaderView(title: group.title, detail: "\(group.rows.count)")

            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)

                    if index < group.rows.count - 1 {
                        Divider()
                            .opacity(0.4)
                            // 分隔线从图标右侧起，视觉上"属于上一行"
                            .padding(.leading, Theme.Spacing.md + 40 + Theme.Spacing.sm)
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

    private func rowView(_ row: SubscriptionListViewModel.RowModel) -> some View {
        SubscriptionRowView(
            row: row,
            onTap: { editorTarget = SubscriptionEditorTarget(mode: .edit(row.id)) },
            onRenew: {
                if let message = viewModel.markRenewed(row) {
                    toast = ToastItem(message: message)
                }
            },
            // 「⋯」菜单（D11）：这三行让"不看说明的人"也能在 3 秒内找到删除。
            // 下面 `.contextMenu` 保留同一套动作作为长按的补充入口。
            onTogglePause: row.status == .cancelled ? nil : {
                if let message = viewModel.togglePause(row) {
                    toast = ToastItem(message: message)
                }
            },
            onDelete: {
                deletionTarget = row
                showsDeleteConfirmation = true
            }
        )
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            if row.status != .cancelled {
                Button {
                    if let message = viewModel.togglePause(row) {
                        toast = ToastItem(message: message)
                    }
                } label: {
                    Label(
                        row.status == .paused ? "恢复" : "暂停",
                        systemImage: row.status == .paused ? "play.fill" : "pause.fill"
                    )
                }
            }

            Button(role: .destructive) {
                deletionTarget = row
                showsDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 动作提示：`ScrollView` 下没有左滑，虽然右侧已有「⋯」，仍给一句话兜底。
    private var hintRow: some View {
        Text("点「⋯」可以暂停或删除订阅（长按也行）")
            .font(Theme.Typography.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.xs)
            .accessibilityHidden(true)
    }

    // MARK: - 空态 / 错误

    private var emptyBlock: some View {
        EmptyStateView(
            iconName: "arrow.triangle.2.circlepath",
            title: "还没有订阅",
            message: "把视频会员、云盘这类固定扣费记进来，每月要花多少一目了然。",
            actionTitle: "新建订阅",
            action: { editorTarget = SubscriptionEditorTarget(mode: .create) }
        )
        .padding(.horizontal, Theme.Spacing.md)
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

            Button("知道了") {
                viewModel.dismissError()
            }
            .font(Theme.Typography.captionStrong)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }
}

// MARK: - Sheet 目标

/// Sheet 的标识（`sheet(item:)` 需要 `Identifiable`）。
///
/// 用 `UUID` 而不是 `mode` 当身份：连续点两次同一行也要能重新弹出表单，
/// 拿 `mode` 当 id 会导致"第二次点没反应"。
private struct SubscriptionEditorTarget: Identifiable {
    let id = UUID()
    let mode: SubscriptionEditorViewModel.Mode
}

// MARK: - 预览

#Preview("订阅列表") {
    SubscriptionListPreview()
}

/// 预览容器：本页依赖 `AppEnvironment`（读服务、dataVersion），
/// 所以必须给它一个内存容器；构造失败时显示一句话而不是崩在预览里。
private struct SubscriptionListPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            NavigationStack {
                SubscriptionListView()
            }
            .environment(environment)
            .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
                .foregroundStyle(.secondary)
        }
    }
}
