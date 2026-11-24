//
//  EntrySheetView.swift
//  一账 / Features / Entry
//
//  职责：记账输入页（T07）——从底部升起的 Sheet，标题「记一笔」，左右「取消 / 保存」。
//
//  版式（自上而下，节奏固定）：
//  类型切换 → 金额大字 → 分类宫格 → 账户 → 日期 / 备注 → **固定键盘**
//
//  三条刻意的设计：
//  ① **键盘常驻、绝不上浮**：金额页最怕"输入时键盘顶一下、上面内容整体跳动"。
//     所以键盘是 `VStack` 的固定成员，不在滚动区里，也不依赖系统键盘；
//     「前 4 次点击就能完成记账」这条验收（FAB → 金额 → 分类 → 保存）依赖它一直在。
//  ② **保存按钮的禁用理由要说出来**：禁用态本身不解释原因是一个常见的设计缺陷。
//     键盘上方那行小字（「输入金额后即可保存」/「请选择转入账户」）就是解释，
//     高度固定 16pt，出现与消失都不会让键盘跳动。
//  ③ **转账隐藏分类**：转账是账户间搬钱，不是消费（PRD 3.2.1），
//     出现分类宫格会让用户以为"转账也要归类"，从而记出一笔分类错误的支出。
//

import SwiftUI

/// 记账输入 Sheet。
struct EntrySheetView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: EntryViewModel

    /// 保存成功回调（首页用它插入高亮 + Toast）。
    var onSaved: (EntrySaveResult) -> Void

    /// 今天（注入以便测试固定时间）。
    private let today: DateOnly

    /// - Parameters:
    ///   - editing: 编辑模式的账目快照；nil 表示新建。
    ///   - today: 今天。
    ///   - onSaved: 保存成功回调。
    init(
        editing: LedgerEntrySnapshot? = nil,
        today: DateOnly = DateOnly(Date()),
        onSaved: @escaping (EntrySaveResult) -> Void
    ) {
        _viewModel = State(initialValue: EntryViewModel(today: today, editing: editing))
        self.today = today
        self.onSaved = onSaved
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: Theme.Spacing.sm) {
                        EntryTypePicker(
                            selected: viewModel.type,
                            onSelect: { viewModel.select(type: $0) }
                        )
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.xs)

                        AmountDisplayView(text: viewModel.amountText, tone: viewModel.amountTone)
                            .padding(.horizontal, Theme.Spacing.md)

                        if viewModel.type.isTransfer {
                            TransferAccountPicker(
                                accounts: viewModel.accounts,
                                sourceID: viewModel.accountID,
                                targetID: viewModel.toAccountID,
                                onSelectSource: { viewModel.select(accountID: $0) },
                                onSelectTarget: { viewModel.select(toAccountID: $0) }
                            )
                        } else {
                            CategoryGridView(
                                categories: viewModel.categories,
                                recentCategories: viewModel.recentCategories,
                                selectedCategoryID: viewModel.highlightedCategoryID,
                                onSelect: { viewModel.select(categoryID: $0) }
                            )

                            AccountPickerRow(
                                accounts: viewModel.accounts,
                                selectedID: viewModel.accountID,
                                onSelect: { viewModel.select(accountID: $0) }
                            )
                        }

                        // 备注在日期之前：备注每次都可能要填，而"改日期"绝大多数时候
                        // 已经被键盘底部的「今天 / 昨天」覆盖了（见 hintBar 里的日期回显）。
                        noteField(text: $viewModel.note)

                        dateRow()

                        if let errorMessage = viewModel.errorMessage {
                            errorRow(message: errorMessage)
                        }

                        // 滚动区底部留白：最后一行不要贴着键盘
                        Color.clear.frame(height: Theme.Spacing.md)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)

                hintBar

                AmountKeypad(
                    onKey: { viewModel.press($0) },
                    selectedDay: viewModel.day,
                    today: viewModel.today,
                    onSelectDay: { viewModel.select(day: $0) }
                )
            }
            .background(Theme.Semantic.pageBackground.ignoresSafeArea())
            .navigationTitle(viewModel.isEditing ? "编辑账目" : "记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("entry.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(Theme.Typography.headline)
                        .disabled(!viewModel.canSave)
                        .accessibilityIdentifier("entry.save")
                }
            }
            .task {
                viewModel.attach(environment)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // 只给内容铺背景不够：安全区（底部 home indicator 那条）会露出下面的首页。
        // `presentationBackground` 把整张 sheet（含安全区）填满，才是"不透"的效果。
        .presentationBackground(Theme.Semantic.pageBackground)
        .accessibilityIdentifier("entry.sheet")
    }

    // MARK: - 子视图

    /// 键盘上方的一行提示：高度固定 16pt，禁用理由与错误都显示在这里。
    private var hintBar: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if let errorMessage = viewModel.errorMessage {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Semantic.danger)
                    .accessibilityHidden(true)
                Text(errorMessage)
                    .foregroundStyle(Theme.Semantic.danger)
            } else if let reason = viewModel.saveDisabledReason {
                Text(reason)
                    .foregroundStyle(.tertiary)
            } else if viewModel.day != viewModel.today {
                // 回填日期会随滚动滑出屏幕，这里常驻一行确认，避免"记错了日子还不知道"
                Text("记为 \(dayText)")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .font(Theme.Typography.caption)
        .lineLimit(1)
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: 16)
        .animation(.easeOut(duration: 0.15), value: viewModel.errorMessage)
    }

    /// 日期行：左侧显示"哪天"，右侧是系统日期选择（记忆点：只允许今天及以前）。
    private func dateRow() -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("日期")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            Text(dayText)
                .font(Theme.Typography.body)
                .monospacedDigit()
                .foregroundStyle(.primary)

            Spacer(minLength: Theme.Spacing.xs)

            DatePicker(
                "日期",
                selection: Binding(
                    get: { viewModel.day.date },
                    set: { viewModel.select(day: DateOnly($0)) }
                ),
                in: ...today.date,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .accessibilityIdentifier("entry.datePicker")
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func noteField(text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text("备注")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
                .padding(.top, Theme.Spacing.xs)

            TextField("加个备注（可选）", text: text, axis: .vertical)
                .font(Theme.Typography.body)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { _, newValue in
                    // 超长直接截断：比"保存时才报错"温和，也比允许写入脏数据安全
                    if newValue.count > EntryViewModel.noteLimit {
                        text.wrappedValue = String(newValue.prefix(EntryViewModel.noteLimit))
                    }
                }
                .accessibilityIdentifier("entry.note")

            if !text.wrappedValue.isEmpty {
                Text("\(text.wrappedValue.count)/\(EntryViewModel.noteLimit)")
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func errorRow(message: String) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Semantic.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Semantic.danger)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// 「11月21日 周五（今天）」/「11月20日 周四」
    private var dayText: String {
        let day = viewModel.day
        let base = "\(day.month)月\(day.day)日 \(day.weekdayName)"
        if day == today { return base + "（今天）" }
        if day == today.adding(days: -1) { return base + "（昨天）" }
        return base
    }

    // MARK: - 动作

    private func save() {
        guard let result = viewModel.save() else { return }
        onSaved(result)
        dismiss()
    }
}

// MARK: - 类型切换

/// 支出 / 收入 / 转账 三挡切换（自绘：系统 `Picker(.segmented)` 不能给每挡不同色调）。
private struct EntryTypePicker: View {

    let selected: EntryType
    var onSelect: (EntryType) -> Void

    private let items: [EntryType] = EntryType.allCases

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { type in
                Button {
                    onSelect(type)
                } label: {
                    Text(type.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(selected == type ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected == type ? tint(for: type) : Color.clear)
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(type.displayName))
                .accessibilityAddTraits(selected == type ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("entry.type.\(type.raw)")
            }
        }
        .padding(Theme.Spacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .animation(.snappy(duration: 0.18), value: selected)
        .accessibilityIdentifier("entry.typePicker")
    }

    private func tint(for type: EntryType) -> Color {
        switch type {
        case .expense: return Theme.Semantic.danger
        case .income: return Theme.Semantic.income
        case .transfer: return Color.accentColor
        }
    }
}

// MARK: - 预览

#Preview("记一笔") {
    EntrySheetPreview()
}

private struct EntrySheetPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            Color.gray
                .sheet(isPresented: .constant(true)) {
                    EntrySheetView(onSaved: { _ in })
                        .environment(environment)
                        .modelContainer(environment.container)
                }
        } else {
            Text("预览数据不可用")
        }
    }
}
