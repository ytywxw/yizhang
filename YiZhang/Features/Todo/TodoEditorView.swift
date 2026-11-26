//
//  TodoEditorView.swift
//  一账 / Features / Todo
//
//  职责：待办新建 / 编辑 / 详情（T17）。
//
//  ## 版式与三处刻意的地方
//
//  ① **「有花销」是整块的开关**：关闭时金额/分类/账户一起隐藏（不是禁用），
//     因为它对这个待办毫无意义；打开后才出现「预计多少 · 记哪一类 · 从哪个账户」。
//  ② **详情态把「预计」和「已记账」分成两行**（R-TODO-6 的 UI 表达）：
//     「预计 ¥200」「已记账 ¥128 ›」。合并成一个数字，就把"当初的计划"和"实际花掉"
//     这两件不同的事永久混在一起了。
//  ③ **关联账目被删时仍显示这一行**（D22）：显示「关联账目已删除 ›」，点进去仍能看详情。
//     不显示会让用户以为这笔钱没记过；直接抹掉关联则会让"撤销删除"恢复不回来。
//

import SwiftUI

// MARK: - 关闭编辑器时交给调用方的信封

/// 编辑器关闭时回传给调用方的结果。
///
/// **为什么删除必须把 `receipt` 一起交出去**：详情页删完就 `dismiss()` 了，
/// 页面上没有地方可以挂一个 3 秒撤销 Toast。撤销窗口由 `TodoListViewModel`
/// 那**一个** `undoExpiryTask` 独占（`undoWindow` 也只有一个常量）。
/// 凭据只有回到列表页，才能接进同一个窗口；让详情页自己再开一个窗口，
/// 屏幕上就会有两条独立的 3 秒计时器 —— 一条过期清掉另一条的凭据，
/// 用户点了「撤销」没反应且没有任何报错。这是明确要避免的形态。
enum TodoEditorResult: Hashable, Sendable {
    /// 保存成功。关联值为 Toast 文案（「已添加待办」/「已保存」）。
    case saved(String)
    /// 删除成功。`message` 是 Toast 文案，`receipt` 是撤销凭据。
    case deleted(message: String, receipt: TodoDeletionReceipt)
}

/// 待办编辑 / 详情页。
struct TodoEditorView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: TodoEditorViewModel
    @State private var toast: ToastItem?
    @State private var showsReopenDialog = false
    @State private var showsDeleteConfirmation = false
    @State private var detailEntryID: UUID?

    /// 完成回调（列表用来弹 Toast；`nil` = 用户取消，什么都没发生）。
    ///
    /// 删除了什么必须原样交出去 —— 调用方（列表页）靠 `receipt` 把这次删除接进
    /// 它自己的 3 秒撤销窗口。见 `TodoEditorResult` 的文档。
    var onFinished: (TodoEditorResult?) -> Void

    /// - Parameters:
    ///   - mode: 新建 / 编辑。
    ///   - today: 今天（测试注入）。
    ///   - onFinished: 关闭回调。
    init(
        mode: TodoEditorViewModel.Mode,
        today: DateOnly = DateOnly(Date()),
        onFinished: @escaping (TodoEditorResult?) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: TodoEditorViewModel(mode: mode, today: today))
        self.onFinished = onFinished
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    if viewModel.isDone {
                        completedSummaryCard
                    }

                    titleCard(text: $viewModel.title)
                    noteCard(text: $viewModel.note)
                    dueCard
                    expenseCard
                    repeatCard
                    priorityCard
                    reminderCard

                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Spacing.md)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if viewModel.mode.isEditing {
                        dangerCard
                    }

                    Color.clear.frame(height: Theme.Spacing.lg)
                }
                .padding(.top, Theme.Spacing.xs)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Semantic.pageBackground)
            .navigationTitle(viewModel.mode.isEditing ? "编辑待办" : "新建待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        // `nil` = 什么都没发生。调用方据此不弹 Toast、也不动撤销窗口。
                        onFinished(nil)
                        dismiss()
                    }
                    .accessibilityIdentifier("todoEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(Theme.Typography.headline)
                        .disabled(!viewModel.canSave)
                        .accessibilityIdentifier("todoEditor.save")
                }
            }
            .task {
                viewModel.attach(environment)
                applyDemoStateIfRequested()
            }
            .toast(item: $toast)
            .confirmationDialog(
                "撤销这个待办的完成？",
                isPresented: $showsReopenDialog,
                titleVisibility: .visible
            ) {
                Button("保留账目") { reopen(keepEntry: true) }
                Button("删除账目", role: .destructive) { reopen(keepEntry: false) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("「保留账目」：这笔钱确实花出去了，只把待办退回未完成。\n「删除账目」：同时把那笔账软删掉（还能撤销）。")
            }
            // 删除确认：**一个** `.confirmationDialog` + 条件按钮，不是叠三个。
            //
            // 叠三个 `.confirmationDialog` 在同一层视图上时，后加的会顶掉先加的，
            // 用户点到的按钮和看到的正文可能不是一回事 —— 这个坑在
            // `TodoListView` 的「删除这一期 / 删除此次及以后」上已经踩过一次，
            // 那里是靠"各自一个状态位"解决的，这里只有一个删除入口，条件按钮就够。
            //
            // 三分支的理由是**详情页必须说出它实际在做的事**：
            //   ① 已完成的那条删的是「一条记录」，重复设置不动（历史记录不该带副作用）；
            //   ② 未完成的重复待办删一次有两种后果（跳过 / 终止），两个都得摆出来；
            //   ③ 非重复就是普通删除，不需要额外解释。
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if viewModel.isDone {
                    Button("删除这条记录", role: .destructive) {
                        // 已完成：只删这一条。走 `deleteAndStopSeries` 而不是裸删是因为
                        // 服务层两个方法已经覆盖了所有删除形态，详情页不留第三条通路。
                        finishDeletion(viewModel.deleteAndStopSeries())
                    }
                    Button("取消", role: .cancel) {}
                } else if viewModel.isRepeating {
                    Button("删除这一期", role: .destructive) {
                        finishDeletion(viewModel.deleteCurrentOccurrence())
                    }
                    Button("删除此次及以后", role: .destructive) {
                        finishDeletion(viewModel.deleteAndStopSeries())
                    }
                    Button("取消", role: .cancel) {}
                } else {
                    Button("删除", role: .destructive) {
                        finishDeletion(viewModel.deleteAndStopSeries())
                    }
                    Button("取消", role: .cancel) {}
                }
            } message: {
                Text(deleteDialogMessage)
            }
            .navigationDestination(item: $detailEntryID) { id in
                EntryDetailView(entryID: id)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Semantic.pageBackground)
        .accessibilityIdentifier("todo.editor")
    }

    // MARK: - 详情态：预计 / 已记账两行

    private var completedSummaryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Semantic.income)
                Text("已完成")
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Spacing.xs)
            }

            if viewModel.hasExpense {
                // 两行并存，绝不合并（R-TODO-6）
                amountLine(
                    label: "预计",
                    value: viewModel.estimatedText ?? "未记录",
                    isPlaceholder: viewModel.estimatedText == nil
                )

                if let linkedID = viewModel.linkedEntryID {
                    Button {
                        detailEntryID = linkedID
                    } label: {
                        amountLine(
                            label: viewModel.linkedEntryDeleted ? "关联账目已删除" : "已记账",
                            value: viewModel.recordedText ?? "—",
                            isPlaceholder: viewModel.recordedText == nil,
                            showsChevron: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("todo.detail.linkedEntry")
                } else {
                    amountLine(label: "已记账", value: "未记账", isPlaceholder: true)
                }
            }

            Button {
                showsReopenDialog = true
            } label: {
                Text("撤销完成")
                    .font(Theme.Typography.captionStrong)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minimumTapSize)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("todo.detail.reopen")
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func amountLine(
        label: String,
        value: String,
        isPlaceholder: Bool,
        showsChevron: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.xs)
            Text(value)
                .font(Theme.Typography.amountSmall)
                .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - 表单

    private func titleCard(text: Binding<String>) -> some View {
        card(title: "标题") {
            TextField("要做什么", text: text)
                .font(Theme.Typography.body)
                .submitLabel(.done)
                .accessibilityIdentifier("todoEditor.title")
        }
    }

    private func noteCard(text: Binding<String>) -> some View {
        card(title: "备注") {
            TextField("补充说明（可以留空）", text: text, axis: .vertical)
                .font(Theme.Typography.body)
                .lineLimit(2...5)
                .accessibilityIdentifier("todoEditor.note")
        }
    }

    private var dueCard: some View {
        @Bindable var viewModel = viewModel

        return card(title: "截止时间") {
            Toggle(isOn: $viewModel.hasDueDate) {
                Text("有截止日期")
                    .font(Theme.Typography.body)
            }
            .accessibilityIdentifier("todoEditor.hasDueDate")

            if viewModel.hasDueDate {
                DatePicker(
                    "日期",
                    selection: Binding(
                        get: { viewModel.dueDay.date },
                        set: { viewModel.dueDay = DateOnly($0) }
                    ),
                    displayedComponents: .date
                )
                .font(Theme.Typography.body)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))

                Toggle(isOn: $viewModel.hasDueTime) {
                    Text("具体时间")
                        .font(Theme.Typography.body)
                }
                .accessibilityIdentifier("todoEditor.hasDueTime")

                if viewModel.hasDueTime {
                    DatePicker(
                        "时间",
                        selection: $viewModel.dueTimeDate,
                        displayedComponents: .hourAndMinute
                    )
                    .font(Theme.Typography.body)
                    .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                }
            }
        }
    }

    /// 「有花销」整块：关闭时金额/分类/账户一起消失。
    private var expenseCard: some View {
        @Bindable var viewModel = viewModel

        return card(title: "花销") {
            Toggle(isOn: Binding(
                get: { viewModel.hasExpense },
                set: { viewModel.setHasExpense($0) }
            )) {
                Text("有花销")
                    .font(Theme.Typography.body)
            }
            .accessibilityIdentifier("todoEditor.hasExpense")

            if viewModel.hasExpense {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                    Text("预计")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text("¥")
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                    TextField("可以不填", text: $viewModel.amountText)
                        .font(Theme.Typography.body)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("todoEditor.amount")
                }

                Text("预计金额可以留空；真花了多少在勾完成时填。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !viewModel.categories.isEmpty {
                    optionRow(
                        title: "分类",
                        options: viewModel.categories.map { ($0.id, $0.name) },
                        selected: viewModel.categoryID,
                        onSelect: { viewModel.select(categoryID: $0) }
                    )
                }

                if !viewModel.accounts.isEmpty {
                    optionRow(
                        title: "账户",
                        options: viewModel.accounts.map { ($0.id, $0.name) },
                        selected: viewModel.accountID,
                        onSelect: { viewModel.select(accountID: $0) }
                    )
                }
            }
        }
    }

    private var repeatCard: some View {
        @Bindable var viewModel = viewModel

        return card(title: "重复") {
            optionRow(
                title: "规则",
                options: RepeatRule.allCases.map { ($0.rawValue, $0.displayName) },
                selected: viewModel.repeatRule.rawValue,
                onSelect: { raw in
                    if let rule = RepeatRule(raw: raw) { viewModel.select(repeatRule: rule) }
                },
                usesStringID: true
            )

            if viewModel.repeatRule != .none {
                Stepper(
                    value: $viewModel.repeatInterval,
                    in: TodoEditorViewModel.repeatIntervalRange
                ) {
                    Text("每 \(viewModel.repeatInterval) 次")
                        .font(Theme.Typography.body)
                }
                .accessibilityIdentifier("todoEditor.repeatInterval")

                Text("改重复规则只影响下一期，已经生成的那一期不会被改动。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var priorityCard: some View {
        @Bindable var viewModel = viewModel

        return card(title: "优先级") {
            optionRow(
                title: "优先级",
                options: TodoPriority.allCases.map { ($0.rawValue, $0.displayName) },
                selected: viewModel.priority.rawValue,
                onSelect: { raw in
                    if let priority = TodoPriority(raw: raw) { viewModel.priority = priority }
                },
                usesStringID: true
            )
        }
    }

    private var reminderCard: some View {
        @Bindable var viewModel = viewModel

        return card(title: "提醒") {
            Toggle(isOn: $viewModel.reminderEnabled) {
                Text("提醒我")
                    .font(Theme.Typography.body)
            }
            .accessibilityIdentifier("todoEditor.reminderEnabled")

            if viewModel.reminderEnabled {
                DatePicker(
                    "日期",
                    selection: Binding(
                        get: { viewModel.reminderDay.date },
                        set: { viewModel.reminderDay = DateOnly($0) }
                    ),
                    displayedComponents: .date
                )
                .font(Theme.Typography.body)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))

                DatePicker(
                    "时间",
                    selection: $viewModel.reminderTimeDate,
                    displayedComponents: .hourAndMinute
                )
                .font(Theme.Typography.body)
                .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
            }
        }
    }

    private var dangerCard: some View {
        card(title: "危险操作") {
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Text("删除待办")
                    .font(Theme.Typography.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Theme.minimumTapSize)
            }
            .accessibilityIdentifier("todoEditor.delete")
        }
    }

    // MARK: - 删除确认的三套文案

    /// 确认弹层的标题（按这条待办的实际状态换）。
    private var deleteDialogTitle: String {
        if viewModel.isDone { return "删除这条记录？" }
        if viewModel.isRepeating { return "删除还是停止重复？" }
        return "删除这条待办？"
    }

    /// 确认弹层的正文。
    ///
    /// 文案里**不出现「明天」**：周期可能是每周 / 每月，只有「下一期」才是与周期无关的说法。
    /// 这是列表页「跳过这一期？」那处已经立下的规矩，两处必须同口径。
    private var deleteDialogMessage: String {
        if viewModel.isDone {
            return "只删掉这一条已完成记录，重复设置不会被修改。已经记过的账目会保留。"
        }
        if viewModel.isRepeating {
            return "「删除这一期」：这一条删掉，下一期照常出现。\n"
                + "「删除此次及以后」：以后不会再出现，已完成的历史记录会保留。"
        }
        return "待办本身会被移除。已经记过的账目会保留。"
    }

    // MARK: - 组件

    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func optionRow(
        title: String,
        options: [(UUID, String)],
        selected: UUID?,
        onSelect: @escaping (UUID) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            chipFlow(options: options, selectedID: selected, onSelect: onSelect)
        }
    }

    private func optionRow(
        title: String,
        options: [(String, String)],
        selected: String?,
        onSelect: @escaping (String) -> Void,
        usesStringID: Bool
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 160), spacing: Theme.Spacing.xs)],
            alignment: .leading,
            spacing: Theme.Spacing.xs
        ) {
            ForEach(options, id: \.0) { option in
                let isSelected = option.0 == selected
                Button {
                    onSelect(option.0)
                } label: {
                    Text(option.1)
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isSelected
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.secondary.opacity(0.10)
                                )
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func chipFlow(
        options: [(UUID, String)],
        selectedID: UUID?,
        onSelect: @escaping (UUID) -> Void
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 160), spacing: Theme.Spacing.xs)],
            alignment: .leading,
            spacing: Theme.Spacing.xs
        ) {
            ForEach(options, id: \.0) { option in
                let isSelected = option.0 == selectedID
                Button {
                    onSelect(option.0)
                } label: {
                    Text(option.1)
                        .font(Theme.Typography.caption)
                        .lineLimit(1)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    isSelected
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.secondary.opacity(0.10)
                                )
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: - 动作

    private func save() {
        guard let result = viewModel.save() else {
            if let message = viewModel.errorMessage {
                toast = ToastItem(message: message)
            }
            return
        }
        // 权限请求时机（T20）：只在"这条待办真的开了提醒"时请求
        if viewModel.reminderEnabled {
            Task { _ = await environment.notifications.requestPermissionIfNeeded() }
        }

        onFinished(.saved(result.isNew ? "已添加待办" : "已保存"))
        dismiss()
    }

    /// 删除 → 把结果原样交给调用方 → 关掉本页。
    ///
    /// 失败时**不 dismiss**：停在当前页把错误显示出来，用户还能重试。
    /// 成功时连撤销凭据一起回传（本页没有撤销 Toast 的位置，见 `TodoEditorResult`）。
    private func finishDeletion(_ result: TodoEditorResult?) {
        guard let result else {
            if let message = viewModel.errorMessage {
                toast = ToastItem(message: message)
            }
            return
        }
        onFinished(result)
        dismiss()
    }

    private func reopen(keepEntry: Bool) {
        if let message = viewModel.reopen(keepEntry: keepEntry) {
            toast = ToastItem(message: message)
        }
    }

    /// 截图用：`-YIZHANG_DEMO_OPEN todo-editor-expense` 时把「有花销」打开。
    ///
    /// 放在视图里而不是初始化参数里：这是**纯演示态**，不该污染公开的 init 签名。
    private func applyDemoStateIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.string(forKey: "YIZHANG_DEMO_OPEN") == "todo-editor-expense" else {
            return
        }
        viewModel.setHasExpense(true)
        if viewModel.title.isEmpty { viewModel.title = "买菜" }
        viewModel.amountText = "86"
        #endif
    }
}

// MARK: - 预览

#Preview("待办编辑") {
    TodoEditorPreview()
}

private struct TodoEditorPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            TodoEditorView(mode: .create)
                .environment(environment)
                .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
                .foregroundStyle(.secondary)
        }
    }
}
