//
//  TodoListView.swift
//  一账 / Features / Todo
//
//  职责：待办页（T16）——订阅扣费只读分组 + 五段待办 + 行内勾选 / 菜单。
//
//  版式（自上而下）：
//  「今天要办 N 件」标题行 → 订阅扣费（折叠）→ 今天 → 本周 → 以后 → 无日期 → 已完成（折叠）
//
//  三条交互约定：
//  ① 勾选框只负责完成；整行点击进详情（两件事分开，避免手滑勾掉）。
//  ② 有花销的待办完成时先弹 T18 确认条；无花销零打扰。
//  ③ 已完成行点击 = 撤销完成，弹三选（保留账目 / 删除账目 / 取消）——这是 R-TODO-7 的 UI。
//

import SwiftUI

/// 待办列表页。
struct TodoListView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = TodoListViewModel()
    @State private var toast: ToastItem?
    @State private var editorTarget: TodoEditorTarget?
    @State private var completionTarget: CompletionTarget?
    @State private var reopenTarget: TodoRowModel?
    @State private var showsReopenDialog = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let errorMessage = viewModel.errorMessage {
                    errorRow(message: errorMessage)
                }

                if viewModel.isEmpty {
                    emptyBlock
                } else {
                    summaryRow

                    if !viewModel.dueItems.isEmpty {
                        SubscriptionDueSection(
                            items: viewModel.dueItems,
                            today: viewModel.today,
                            isExpanded: viewModel.isDueSectionExpanded,
                            total: viewModel.dueTotal,
                            onToggle: { viewModel.toggleDueSection() },
                            onSelect: { id in editorTarget = TodoEditorTarget(mode: .subscription(id)) }
                        )
                    }

                    ForEach(viewModel.visibleGroups) { group in
                        groupBlock(group)
                    }

                    if let completed = viewModel.completedGroup {
                        completedToggleBlock(completed)
                    }
                }
            }
            .padding(.top, Theme.Spacing.xs)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Semantic.pageBackground)
        .navigationTitle("待办")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = TodoEditorTarget(mode: .todo(.create))
                } label: {
                    Image(systemName: "plus")
                        .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                }
                .accessibilityLabel(Text("新建待办"))
                .accessibilityIdentifier("todo.add")
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            viewModel.attach(environment)
            openDemoScreenIfRequested()
        }
        .task(id: environment.dataVersion) {
            viewModel.load()
        }
        .toast(item: $toast)
        .sheet(item: $editorTarget) { target in
            switch target.mode {
            case .todo(let mode):
                TodoEditorView(mode: mode, today: viewModel.today) { message in
                    if let message { toast = ToastItem(message: message) }
                }
            case .subscription(let id):
                SubscriptionEditorView(mode: .edit(id), today: viewModel.today) { message in
                    if let message { toast = ToastItem(message: message) }
                }
            }
        }
        .sheet(item: $completionTarget) { target in
            TodoCompletionSheet(request: target.request) { message in
                completionTarget = nil
                if let message { toast = ToastItem(message: message) }
            }
        }
        .confirmationDialog(
            "撤销这个待办的完成？",
            isPresented: $showsReopenDialog,
            titleVisibility: .visible,
            presenting: reopenTarget
        ) { row in
            Button("保留账目") {
                if let message = viewModel.reopen(id: row.id, keepEntry: true) {
                    toast = ToastItem(message: message)
                }
                reopenTarget = nil
            }
            Button("删除账目", role: .destructive) {
                if let message = viewModel.reopen(id: row.id, keepEntry: false) {
                    toast = ToastItem(message: message)
                }
                reopenTarget = nil
            }
            Button("取消", role: .cancel) {
                reopenTarget = nil
            }
        } message: { _ in
            Text("「保留账目」：这笔钱确实花出去了，只把待办退回未完成。\n「删除账目」：同时把那笔账软删掉（还能撤销）。")
        }
        .accessibilityIdentifier("todo.list")
    }

    // MARK: - 顶部

    /// 「今天要办 N 件」——**只数待办，不含订阅扣费派生项**（R-MIX-3）。
    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text("今天要办 \(viewModel.todayCount) 件")
                .font(Theme.Typography.headline)
                .foregroundStyle(.primary)

            if viewModel.overdueCount > 0 {
                Text("其中 \(viewModel.overdueCount) 件已逾期")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Semantic.danger)
            }

            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("todo.summary")
    }

    // MARK: - 分组

    private func groupBlock(_ group: TodoGroupModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderView(title: group.title, detail: group.detailText)

            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < group.rows.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .padding(.leading, Theme.Spacing.md + Theme.minimumTapSize)
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

    private func rowView(_ row: TodoRowModel) -> some View {
        TodoRowView(
            row: row,
            onToggle: { toggle(row) },
            onTap: { open(row) },
            onPostpone: row.isDone ? nil : { postpone(row) },
            onDelete: { delete(row) }
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// 已完成分组的折叠头（默认收起 → 这里画「已完成 N」一行）。
    private func completedToggleBlock(_ group: TodoGroupModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                viewModel.toggleCompletedCollapsed()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text("已完成 \(group.count)")
                        .font(Theme.Typography.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Theme.Spacing.xs)
                    Image(systemName: viewModel.isCompletedCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .frame(minHeight: Theme.minimumTapSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("已完成 \(group.count) 条"))
            .accessibilityHint(Text(viewModel.isCompletedCollapsed ? "展开" : "收起"))
            .accessibilityIdentifier("todo.completedToggle")

            if !viewModel.isCompletedCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                        if index < group.rows.count - 1 {
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, Theme.Spacing.md + Theme.minimumTapSize)
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
    }

    // MARK: - 空态 / 错误

    private var emptyBlock: some View {
        EmptyStateView(
            iconName: "checklist",
            title: "还没有待办",
            message: "把要做的事记下来，勾掉一件就少一件。",
            actionTitle: "加一条",
            action: { editorTarget = TodoEditorTarget(mode: .todo(.create)) }
        )
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xl)
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

    // MARK: - 动作

    private func toggle(_ row: TodoRowModel) {
        if row.isDone {
            reopenTarget = row
            showsReopenDialog = true
            return
        }
        if let request = viewModel.complete(id: row.id) {
            // 有花销 → 弹确认条（T18）；无花销时 viewModel 已经直接完成并返回 nil
            completionTarget = CompletionTarget(request: request)
        }
    }

    private func open(_ row: TodoRowModel) {
        if row.isDone {
            reopenTarget = row
            showsReopenDialog = true
        } else {
            editorTarget = TodoEditorTarget(mode: .todo(.edit(row.id)))
        }
    }

    private func postpone(_ row: TodoRowModel) {
        if let message = viewModel.postponeToTomorrow(id: row.id) {
            toast = ToastItem(message: message)
        }
    }

    private func delete(_ row: TodoRowModel) {
        if let message = viewModel.delete(id: row.id) {
            toast = ToastItem(message: message)
        }
    }

    // MARK: - DEBUG 截图钩子

    /// 让三张验收截图可以在无头模拟器上取到（无法合成点击手势）。
    ///
    /// ```sh
    /// xcrun simctl launch booted com.xiaoban.yizhang \
    ///     -YIZHANG_INITIAL_TAB todo -YIZHANG_DEMO_TODOS 1 -YIZHANG_DEMO_OPEN todo-editor
    /// ```
    private func openDemoScreenIfRequested() {
        #if DEBUG
        guard let target = UserDefaults.standard.string(forKey: "YIZHANG_DEMO_OPEN") else { return }
        switch target {
        case "todo-editor":
            editorTarget = TodoEditorTarget(mode: .todo(.create))
        case "todo-editor-expense":
            editorTarget = TodoEditorTarget(mode: .todo(.create))
        case "todo-completion":
            // 拿第一条"带花销且未完成"的待办来演示确认条
            if let request = viewModel.completeFirstExpenseTodo() {
                completionTarget = CompletionTarget(request: request)
            }
        case "todo-completed-expanded":
            viewModel.isCompletedCollapsed = false
        default:
            break
        }
        #endif
    }
}

// MARK: - Sheet 目标

/// 待办页会打开的两类编辑页。
private struct TodoEditorTarget: Identifiable {

    enum Mode: Hashable {
        case todo(TodoEditorViewModel.Mode)
        case subscription(UUID)
    }

    let id = UUID()
    let mode: Mode
}

/// 完成确认条的载体（`TodoCompletionRequest` 不是 `Identifiable`）。
private struct CompletionTarget: Identifiable {
    let id = UUID()
    let request: TodoCompletionRequest
}

// MARK: - 预览

#Preview("待办列表") {
    TodoListPreview()
}

/// 预览容器：本页依赖 `AppEnvironment`，所以给它一个内存容器。
private struct TodoListPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            NavigationStack {
                TodoListView()
            }
            .environment(environment)
            .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
                .foregroundStyle(.secondary)
        }
    }
}
