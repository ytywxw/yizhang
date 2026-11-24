//
//  EntryFilterSheet.swift
//  一账 / Features / Ledger
//
//  职责：账目筛选面板（T09）——时间 / 类型 / 分类 / 账户 / 来源 / 关键词 六个维度。
//
//  为什么面板里维护一份 `draft` 而不是直接改父级条件：
//  筛选是"调好再应用"的动作。边调边刷列表会让列表在面板下面反复跳动，
//  用户既看不清自己在选什么，也失去了「取消」的意义。
//
//  为什么六个维度全塞在一个面板里（而不是分成六个二级页）：
//  真实使用中"筛一个分类"和"筛这个分类下支付宝的那几笔"是同一个念头的两步，
//  分页会让第二步回到第一步重新找入口。一屏放得下（≤ 19 分类 + 5 账户），就不要分页。
//
//  本组件不做任何匹配判断：命中逻辑在 `EntryFilter`（Domain，已单测），
//  这里只负责把用户的点击变成 `EntryFilter` 字段。
//

import SwiftUI

/// 筛选面板。
struct EntryFilterSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// 正在编辑的条件（点「应用」才提交）。
    @State private var draft: EntryFilter

    let categories: [CategoryOption]
    let accounts: [AccountOption]
    let today: DateOnly

    /// 应用回调。
    var onApply: (EntryFilter) -> Void

    init(
        filter: EntryFilter,
        categories: [CategoryOption],
        accounts: [AccountOption],
        today: DateOnly,
        onApply: @escaping (EntryFilter) -> Void
    ) {
        _draft = State(initialValue: filter)
        self.categories = categories
        self.accounts = accounts
        self.today = today
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.sm) {
                    timeSection
                    typeSection
                    sourceSection
                    categorySection
                    accountSection
                    keywordSection
                    Color.clear.frame(height: Theme.Spacing.sm)
                }
                .padding(.top, Theme.Spacing.xs)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.Semantic.pageBackground)
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isActive ? "应用（\(draft.activeDimensionCount)）" : "应用") {
                        onApply(draft)
                        dismiss()
                    }
                    .font(Theme.Typography.headline)
                    .accessibilityIdentifier("filter.apply")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("filter.sheet")
    }

    // MARK: - 时间

    private var timeSection: some View {
        sectionCard(title: "时间") {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                chipFlow {
                    ForEach(EntryFilter.TimeScope.allCases, id: \.self) { scope in
                        FilterChip(
                            title: scope.displayName,
                            isSelected: draft.time == scope
                        ) {
                            draft.time = scope
                            if scope != .custom {
                                draft.customStartDay = 0
                                draft.customEndDay = 0
                            } else if draft.customStartDay == 0 {
                                // 进自定义先给一个可用区间（本月 1 日 → 今天），而不是两个空选择器
                                draft.customStartDay = DateOnly.monthRange(today.monthKey).lowerBound
                                draft.customEndDay = today.key
                            }
                        }
                    }
                }

                if draft.time == .custom {
                    customRangePickers
                }
            }
        }
    }

    private var customRangePickers: some View {
        HStack(spacing: Theme.Spacing.xs) {
            DatePicker(
                "从",
                selection: Binding(
                    get: { DateOnly(key: draft.customStartDay).date },
                    set: { newValue in
                        let day = DateOnly(newValue)
                        draft.customStartDay = day.key
                        if draft.customEndDay < day.key { draft.customEndDay = day.key }
                    }
                ),
                in: ...today.date,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

            DatePicker(
                "到",
                selection: Binding(
                    get: {
                        DateOnly(key: draft.customEndDay > 0 ? draft.customEndDay : today.key).date
                    },
                    set: { newValue in
                        let day = DateOnly(newValue)
                        draft.customEndDay = day.key
                        if draft.customStartDay > day.key { draft.customStartDay = day.key }
                    }
                ),
                in: ...today.date,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
        }
        .font(Theme.Typography.caption)
    }

    // MARK: - 类型 / 来源

    private var typeSection: some View {
        sectionCard(title: "类型") {
            chipFlow {
                ForEach(EntryType.allCases, id: \.self) { type in
                    FilterChip(title: type.displayName, isSelected: draft.types.contains(type)) {
                        draft.toggleType(type)
                    }
                }
            }
        }
    }

    private var sourceSection: some View {
        sectionCard(title: "来源") {
            chipFlow {
                ForEach(EntrySource.allCases, id: \.self) { source in
                    FilterChip(
                        title: source == .manual ? "手动记账" : "\(source.displayName)记账",
                        isSelected: draft.sources.contains(source)
                    ) {
                        draft.toggleSource(source)
                    }
                }
            }
        }
    }

    // MARK: - 分类 / 账户

    private var categorySection: some View {
        sectionCard(title: "分类") {
            if categories.isEmpty {
                emptyHint("没有可选分类")
            } else {
                chipFlow {
                    ForEach(categories) { category in
                        FilterChip(
                            title: category.name,
                            isSelected: draft.categoryIDs.contains(category.id)
                        ) {
                            draft.toggleCategory(category.id)
                        }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        sectionCard(title: "账户") {
            if accounts.isEmpty {
                emptyHint("没有可选账户")
            } else {
                chipFlow {
                    ForEach(accounts) { account in
                        FilterChip(
                            title: account.name,
                            isSelected: draft.accountIDs.contains(account.id)
                        ) {
                            draft.toggleAccount(account.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 关键词

    private var keywordSection: some View {
        sectionCard(title: "备注包含") {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                TextField("比如：午饭、房租", text: $draft.keyword)
                    .font(Theme.Typography.body)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("filter.keyword")

                if !draft.keyword.isEmpty {
                    Button {
                        draft.keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("清空关键词"))
                }
            }
            .frame(minHeight: Theme.minimumTapSize)
        }
    }

    // MARK: - 布局工具

    /// 分组卡片：标题 + 内容，视觉与首页的分组一致。
    private func sectionCard<Content: View>(
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

    /// chips 自动换行（`FlowLayout` 在 iOS 17 需要自己写，这里用 `LazyVGrid` 近似：
    /// 分类名长短差异大，固定列宽会截断，所以用自适应列数）。
    private func chipFlow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 160), spacing: Theme.Spacing.xs)],
            alignment: .leading,
            spacing: Theme.Spacing.xs
        ) {
            content()
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Chip

/// 可多选的筛选标签。
private struct FilterChip: View {

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

#Preview("筛选") {
    EntryFilterSheet(
        filter: EntryFilter(),
        categories: [
            CategoryOption(id: UUID(), name: "餐饮", iconName: "fork.knife", colorHex: "#C0392B", type: .expense),
            CategoryOption(id: UUID(), name: "买菜生鲜", iconName: "cart", colorHex: "#2E7D32", type: .expense),
            CategoryOption(id: UUID(), name: "工资", iconName: "banknote", colorHex: "#2E7D32", type: .income)
        ],
        accounts: [
            AccountOption(id: UUID(), name: "现金", symbolName: AccountKind.cash.symbolName),
            AccountOption(id: UUID(), name: "微信", symbolName: AccountKind.wechat.symbolName)
        ],
        today: DateOnly(year: 2026, month: 11, day: 21) ?? .zero,
        onApply: { _ in }
    )
}
