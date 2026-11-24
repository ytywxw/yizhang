//
//  SubscriptionEditorView.swift
//  一账 / Features / Subscription
//
//  职责：订阅编辑页（T13）——新建与编辑同一个表单，底部另给「取消订阅」「删除订阅」。
//
//  版式（自上而下）：名称 → 金额 → 周期 → 首次扣费日 →（试用？试用结束日 : 下次扣费日）
//  → 自动续费 → 分类 → 账户 → 备注 → 提醒 → 危险区（仅编辑）
//
//  三处刻意的地方：
//  ① **试用期只显示一个日期**：试用中下次扣费日就是试用结束日（E-1），
//     两个日期并排会让人以为"试用期内还会扣一次"。
//  ② **手改「下次扣费日」出现「以此为准」**：锚定日会被服务层重置（R-SUB-8 / E-10），
//     界面只负责告诉用户"你改了，从现在起听你的"，绝不自算。
//  ③ **危险区两个动作分开**：「取消订阅」保留订阅与历史；「删除订阅」抹掉订阅本身。
//     两个都做二次确认，且删除按钮是红的——这是全 App 唯一不可逆的入口。
//
//  本页不做任何业务计算：校验、日期对齐、补录选项全在 `SubscriptionEditorViewModel`。
//

import SwiftUI

/// 订阅编辑页。
struct SubscriptionEditorView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: SubscriptionEditorViewModel
    @State private var toast: ToastItem?
    @State private var pendingBackfill: PendingBackfill?
    @State private var showsCancelConfirmation = false
    @State private var showsDeleteConfirmation = false

    /// 完成回调（列表用来弹 Toast；`nil` 表示用户直接关掉了）。
    var onFinished: (String?) -> Void

    /// - Parameters:
    ///   - mode: 新建 / 编辑。
    ///   - today: 今天（测试注入）。
    ///   - onFinished: 关闭回调，携带要展示的一句话（`nil` = 不提示）。
    init(
        mode: SubscriptionEditorViewModel.Mode,
        today: DateOnly = DateOnly(Date()),
        onFinished: @escaping (String?) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: SubscriptionEditorViewModel(mode: mode, today: today))
        self.onFinished = onFinished
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    nameCard(text: $viewModel.name)
                    amountCard(text: $viewModel.amountText)
                    cycleCard
                    dateCard
                    switchesCard
                    categoryCard
                    accountCard
                    noteCard(text: $viewModel.note)
                    reminderCard

                    if viewModel.mode.isEditing {
                        dangerCard
                    }

                    if let errorMessage = viewModel.errorMessage {
                        errorRow(message: errorMessage)
                    }

                    Color.clear.frame(height: Theme.Spacing.lg)
                }
                .padding(.top, Theme.Spacing.xs)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Semantic.pageBackground)
            .navigationTitle(viewModel.mode.isEditing ? "编辑订阅" : "新建订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onFinished(nil)
                        dismiss()
                    }
                    .accessibilityIdentifier("subEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(Theme.Typography.headline)
                        .disabled(!viewModel.canSave)
                        .accessibilityIdentifier("subEditor.save")
                }
            }
            .task {
                viewModel.attach(environment)
            }
            .toast(item: $toast)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Semantic.pageBackground)
        .sheet(item: $pendingBackfill) { pending in
            BackfillPromptView(option: pending.option) { cycles in
                let inserted = viewModel.backfill(
                    subscriptionID: pending.option.subscriptionID,
                    cycles: cycles
                )
                pendingBackfill = nil
                onFinished(inserted > 0 ? "已补录 \(inserted) 笔" : nil)
                dismiss()
            } onSkip: {
                pendingBackfill = nil
                onFinished(nil)
                dismiss()
            }
        }
        .confirmationDialog(
            "取消这个订阅？",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("取消订阅", role: .destructive) {
                if let message = viewModel.cancelSubscription() {
                    onFinished(message)
                    dismiss()
                }
            }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("订阅会标记为「已取消」，不再自动生成账目。历史账目和总览都保留，之后还可以重新激活。")
        }
        .confirmationDialog(
            "彻底删除这个订阅？",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除订阅", role: .destructive) {
                if let message = viewModel.deleteSubscription() {
                    onFinished(message)
                    dismiss()
                }
            }
            Button("再想想", role: .cancel) {}
        } message: {
            Text("订阅本身会被移除（无法恢复）。已经生成的账目会保留，但在账目详情里会显示「来源已删除」。如果只是想停掉自动记账，选「取消订阅」更好。")
        }
        .accessibilityIdentifier("subEditor.root")
    }

    // MARK: - 卡片

    private func nameCard(text: Binding<String>) -> some View {
        card(title: "名称") {
            TextField("比如：视频会员", text: text)
                .font(Theme.Typography.body)
                .frame(minHeight: Theme.minimumTapSize)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if newValue.count > SubscriptionEditorViewModel.nameLimit {
                        text.wrappedValue = String(newValue.prefix(SubscriptionEditorViewModel.nameLimit))
                    }
                }
                .accessibilityIdentifier("subEditor.name")
        }
    }

    private func amountCard(text: Binding<String>) -> some View {
        card(title: "金额") {
            HStack(spacing: Theme.Spacing.xs) {
                Text("¥")
                    .font(Theme.Typography.amountMedium)
                    .foregroundStyle(.secondary)

                TextField("0", text: text)
                    .font(Theme.Typography.amountMedium)
                    .monospacedDigit()
                    .keyboardType(.decimalPad)
                    .frame(minHeight: Theme.minimumTapSize)
                    .accessibilityIdentifier("subEditor.amount")

                Text(viewModel.cycleText + " 扣一次")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(viewModel.amountDisplayText)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("subEditor.amountHint")
        }
    }

    private var cycleCard: some View {
        card(title: "周期") {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                chipRow {
                    ForEach(CyclePreset.allCases, id: \.self) { preset in
                        EditorChip(
                            title: preset.displayName,
                            isSelected: viewModel.preset == preset
                        ) {
                            viewModel.select(preset: preset)
                        }
                    }
                }

                if viewModel.preset == .custom {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("每")
                            .font(Theme.Typography.body)
                            .foregroundStyle(.secondary)

                        TextField(
                            "30",
                            value: Binding(
                                get: { viewModel.customValue },
                                set: { viewModel.customValue = min(max($0, 1), 366) }
                            ),
                            format: .number
                        )
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 64, height: Theme.minimumTapSize)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(Color.secondary.opacity(0.1))
                        )
                        .accessibilityIdentifier("subEditor.customValue")

                        EditorChip(
                            title: "天",
                            isSelected: viewModel.customUnit == .day
                        ) { viewModel.select(customUnit: .day) }

                        EditorChip(
                            title: "个月",
                            isSelected: viewModel.customUnit == .month
                        ) { viewModel.select(customUnit: .month) }
                    }
                }
            }
        }
    }

    private var dateCard: some View {
        card(title: "日期") {
            VStack(spacing: Theme.Spacing.xs) {
                dateRow(
                    title: "首次扣费日",
                    day: Binding(
                        get: { viewModel.firstBillingDay.date },
                        set: { viewModel.select(firstBillingDay: DateOnly($0)) }
                    ),
                    identifier: "subEditor.firstBilling"
                )

                if viewModel.isInTrial {
                    // 试用中：下次扣费日就是试用结束日，只显示一个（E-1）
                    dateRow(
                        title: "下次扣费日",
                        day: .constant(viewModel.effectiveNextBillingDay.date),
                        identifier: "subEditor.nextBilling",
                        isLocked: true,
                        footnote: "试用中，试用结束当天开始扣费"
                    )
                } else {
                    dateRow(
                        title: "下次扣费日",
                        day: Binding(
                            get: { viewModel.nextBillingDay.date },
                            set: { viewModel.select(nextBillingDay: DateOnly($0)) }
                        ),
                        identifier: "subEditor.nextBilling",
                        footnote: viewModel.didOverrideNextBilling
                            ? "已手改，以此为准（金额按上面的周期继续往后推）"
                            : nil
                    )
                }
            }
        }
    }

    private var switchesCard: some View {
        card(title: "续费与试用") {
            VStack(spacing: Theme.Spacing.xs) {
                Toggle(isOn: Binding(
                    get: { viewModel.autoRenew },
                    set: { viewModel.autoRenew = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动续费")
                            .font(Theme.Typography.body)
                        Text("关掉后到期只提醒，点「已续费」才生成账目")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: Theme.minimumTapSize)
                .accessibilityIdentifier("subEditor.autoRenew")

                Divider().opacity(0.4)

                Toggle(isOn: Binding(
                    get: { viewModel.hasTrial },
                    set: { viewModel.setTrialEnabled($0) }
                )) {
                    Text("有免费试用")
                        .font(Theme.Typography.body)
                }
                .frame(minHeight: Theme.minimumTapSize)
                .accessibilityIdentifier("subEditor.hasTrial")

                if viewModel.hasTrial {
                    dateRow(
                        title: "试用结束日",
                        day: Binding(
                            get: { viewModel.trialEndDay.date },
                            set: { viewModel.trialEndDay = DateOnly($0) }
                        ),
                        identifier: "subEditor.trialEnd"
                    )
                }
            }
        }
    }

    private var categoryCard: some View {
        card(title: "分类") {
            if viewModel.categories.isEmpty {
                Text("没有可用的支出分类")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            } else {
                chipRow {
                    ForEach(viewModel.categories) { category in
                        EditorChip(
                            title: category.name,
                            isSelected: viewModel.categoryID == category.id
                        ) {
                            viewModel.select(categoryID: category.id)
                        }
                    }
                }
            }
        }
    }

    private var accountCard: some View {
        card(title: "扣费账户") {
            chipRow {
                ForEach(viewModel.accounts) { account in
                    EditorChip(
                        title: account.name,
                        isSelected: viewModel.accountID == account.id
                    ) {
                        viewModel.select(accountID: account.id)
                    }
                }
            }
        }
    }

    private func noteCard(text: Binding<String>) -> some View {
        card(title: "备注") {
            TextField("比如：家庭共享账号", text: text, axis: .vertical)
                .font(Theme.Typography.body)
                .lineLimit(1...3)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if newValue.count > SubscriptionEditorViewModel.noteLimit {
                        text.wrappedValue = String(
                            newValue.prefix(SubscriptionEditorViewModel.noteLimit)
                        )
                    }
                }
                .accessibilityIdentifier("subEditor.note")
        }
    }

    private var reminderCard: some View {
        card(title: "提前提醒") {
            chipRow {
                ForEach(SubscriptionEditorViewModel.reminderChoices, id: \.self) { days in
                    EditorChip(
                        title: days == 0 ? "当天" : "\(days) 天前",
                        isSelected: viewModel.reminderDays == days
                    ) {
                        viewModel.reminderDays = days
                    }
                }
            }
        }
    }

    private var dangerCard: some View {
        card(title: "订阅状态") {
            VStack(spacing: Theme.Spacing.xs) {
                Button {
                    showsCancelConfirmation = true
                } label: {
                    HStack {
                        Text("取消订阅")
                            .font(Theme.Typography.body)
                        Spacer()
                        Text("保留历史")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: Theme.minimumTapSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status == .cancelled)
                .accessibilityIdentifier("subEditor.cancelSubscription")

                Divider().opacity(0.4)

                Button {
                    showsDeleteConfirmation = true
                } label: {
                    HStack {
                        Text("删除订阅")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Semantic.danger)
                        Spacer()
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Semantic.danger)
                    }
                    .frame(minHeight: Theme.minimumTapSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("subEditor.deleteSubscription")
            }
        }
    }

    // MARK: - 工具

    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.captionStrong)
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

    private func chipRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 160), spacing: Theme.Spacing.xs)],
            alignment: .leading,
            spacing: Theme.Spacing.xs
        ) {
            content()
        }
    }

    private func dateRow(
        title: String,
        day: Binding<Date>,
        identifier: String,
        isLocked: Bool = false,
        footnote: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(isLocked ? .secondary : .primary)

                Spacer(minLength: Theme.Spacing.xs)

                DatePicker(
                    title,
                    selection: day,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .disabled(isLocked)
                .accessibilityIdentifier(identifier)
            }
            .frame(minHeight: Theme.minimumTapSize)

            if let footnote {
                Text(footnote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorRow(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Semantic.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Semantic.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - 动作

    private func save() {
        guard let result = viewModel.save() else {
            // 校验失败：错误已经写进 VM，这里只把它滚进视野（弹 Toast 会盖住错误行）
            if let message = viewModel.errorMessage {
                toast = ToastItem(message: message)
            }
            return
        }

        if result.needsBackfillDecision, let option = result.backfill {
            // 先别关：让用户决定要不要补历史（默认不补，E-5）
            pendingBackfill = PendingBackfill(option: option)
            return
        }

        // 权限请求时机（T20）：只在"用户第一次建了带提醒的东西"时请求，不在冷启动问。
        // 被拒不打断任何流程——订阅已经存好了。
        if viewModel.reminderDays > 0 {
            Task { _ = await environment.notifications.requestPermissionIfNeeded() }
        }

        onFinished(result.sweepGeneratedCount > 0 ? "已保存，生成 \(result.sweepGeneratedCount) 笔账目" : "已保存")
        dismiss()
    }
}

// MARK: - 补录询问

/// `.sheet(item:)` 要的 `Identifiable` 包装。
///
/// 刻意不直接让 `BackfillOption` 兼容 `Identifiable`：那是领域层的纯数据，
/// 它的身份对 UI 没有意义（同一个订阅可以先后弹两次补录询问），
/// 每次弹窗都该是一次新的展示。
private struct PendingBackfill: Identifiable {
    let id = UUID()
    let option: BackfillOption
}

/// 补录询问（E-5）：默认「不补」，可选 1…min(N, 12)。
struct BackfillPromptView: View {

    let option: BackfillOption

    var onConfirm: (Int) -> Void
    var onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cycles: Int = BackfillOption.defaultCycles

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.md) {
                Text(option.promptText)
                    .font(Theme.Typography.body)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.md)

                if let earliest = option.earliestDay, let latest = option.latestDay {
                    Text("最早 \(earliest.fullDisplayString)，最近 \(latest.fullDisplayString)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("补录期数", selection: $cycles) {
                    ForEach(option.selectableCycles, id: \.self) { value in
                        Text(value == 0 ? "不补" : "补最近 \(value) 期").tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxHeight: 160)

                Text("补录会按每期应扣日生成账目，会计入对应月份的支出统计。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.md)

                Spacer(minLength: 0)

                Button {
                    onConfirm(cycles)
                    dismiss()
                } label: {
                    Text(cycles == 0 ? "不补，直接完成" : "补 \(cycles) 期")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, Theme.Spacing.md)
                .accessibilityIdentifier("backfill.confirm")

                Button("以后再说") {
                    onSkip()
                    dismiss()
                }
                .font(Theme.Typography.caption)
                .frame(minHeight: Theme.minimumTapSize)
                .accessibilityIdentifier("backfill.skip")
            }
            .padding(.vertical, Theme.Spacing.md)
            .background(Theme.Semantic.pageBackground)
            .navigationTitle("补录历史账目")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationBackground(Theme.Semantic.pageBackground)
    }
}

// MARK: - 选项 chip

/// 编辑页用的小胶囊（与筛选面板的样式一致，但**不带** `maxWidth: .infinity`，
/// 因为这里是"选一个"而不是"列一堆"）。
private struct EditorChip: View {

    let title: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.minimumTapSize)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 预览

#Preview("新建订阅") {
    SubscriptionEditorPreview()
}

private struct SubscriptionEditorPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            Color.gray
                .sheet(isPresented: .constant(true)) {
                    SubscriptionEditorView(mode: .create)
                        .environment(environment)
                        .modelContainer(environment.container)
                }
        } else {
            Text("预览数据不可用")
        }
    }
}
