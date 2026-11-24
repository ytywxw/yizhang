//
//  CategoryRankingView.swift
//  一账 / Features / Statistics
//
//  职责：分类排行（环形图下方）+ 下钻后的分类账目列表（T19）。
//
//  排行不是"图表的附属说明"，而是**图表的等价入口**：
//  扇区不好点、色觉障碍用户分不清颜色时，这一列（图标 + 名称 + 金额 + 占比）
//  才是可靠的那一条路径。所以它和扇区调同一个 `onSelect`。
//

import SwiftUI

// MARK: - 排行

/// 分类排行列表。
struct CategoryRankingView: View {

    let shares: [CategoryShare]
    let title: (CategoryShare) -> String
    let iconName: (CategoryShare) -> String
    let colorHex: (CategoryShare) -> String
    var onSelect: (CategoryShare) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                Button {
                    onSelect(share)
                } label: {
                    row(share)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stats.ranking.row")

                if index < shares.count - 1 {
                    Divider()
                        .opacity(0.4)
                        .padding(.leading, Theme.Spacing.md + 28 + Theme.Spacing.sm)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
        .accessibilityIdentifier("stats.ranking")
    }

    private func row(_ share: CategoryShare) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            CategoryGlyph(
                iconName: iconName(share),
                colorHex: colorHex(share),
                size: .small
            )

            Text(title(share))
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.xs)

            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(share.amount.formatted())
                    .font(Theme.Typography.amountSmall)
                    .foregroundStyle(.primary)

                Text("\(share.percent)%")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: Theme.minimumTapSize)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title(share))，\(share.amount.formatted())，占 \(share.percent)%"))
    }
}

// MARK: - 下钻：某个分类的账目列表

/// 分类账目列表（从环形图 / 排行下钻进入）。
///
/// 刻意做成**轻量只读列表**而不是复用 `LedgerHomeView`：
/// ① 那边是"月度 + 筛选器"的复杂状态机，套进来会带一堆与本次下钻无关的筛选；
/// ② 这里只需要"这个分类、这个范围、按日期倒序"，5 行取数就能覆盖。
struct CategoryEntriesView: View {

    @Environment(AppEnvironment.self) private var environment

    let categoryTitle: String
    let range: StatisticsRange
    let today: DateOnly
    /// 合并桶 / 未分类时为 nil → 不过滤分类。
    let categoryID: UUID?
    let isMerged: Bool
    /// 「其他」桶里到底合并了哪些分类（为空时退化为不过滤）。
    var mergedCategoryIDs: Set<UUID> = []

    @State private var rows: [Row] = []
    @State private var errorMessage: String?

    /// 一行账目（只读快照）。
    struct Row: Identifiable, Hashable {
        let id: UUID
        let day: DateOnly
        let amount: Money
        let note: String
        let accountName: String?
        let iconName: String
        let colorHex: String
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                        .padding(Theme.Spacing.md)
                } else if rows.isEmpty {
                    Text("这个分类在这个范围内没有记录")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(Theme.Spacing.lg)
                } else {
                    totalRow

                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row)
                            if index < rows.count - 1 {
                                Divider()
                                    .opacity(0.4)
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
            .padding(.top, Theme.Spacing.xs)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Semantic.pageBackground)
        .navigationTitle(categoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .task(id: environment.dataVersion) { load() }
        .accessibilityIdentifier("stats.categoryEntries")
    }

    private var totalRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("合计")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.xs)
            Text(total.formatted())
                .font(Theme.Typography.amountSmall)
                .foregroundStyle(.primary)
            Text("共 \(rows.count) 笔")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var total: Money {
        rows.reduce(Money.zero) { $0 + $1.amount }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            CategoryGlyph(iconName: row.iconName, colorHex: row.colorHex, size: .medium)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(row.note.isEmpty ? categoryTitle : row.note)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.xxs) {
                    Text(row.day.displayString)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    if let account = row.accountName {
                        Text("·")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.tertiary)
                        Text(account)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: Theme.Spacing.xs)

            Text(row.amount.formatted())
                .font(Theme.Typography.amountSmall)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: Theme.minimumTapSize)
    }

    // MARK: 取数

    private func load() {
        do {
            let bounds = StatisticsCalculator.dayRange(of: range, today: today)
            let entries = try environment.readContext
                .fetch(QueryDescriptors.allEntries())
                .filter { entry in
                    guard entry.deletedAt == nil,
                          entry.typeRaw == EntryType.expense.raw,
                          entry.amount > 0,
                          bounds.contains(entry.occurredDay) else { return false }
                    // 合并桶（「其他」）与未分类：按"不在前 8 名里"无法反推，
                    // 所以合并桶直接用金额区间匹配（见 `SharingBucketMatcher`）
                    return matches(entry)
                }

            rows = entries
                .sorted { $0.occurredDay > $1.occurredDay }
                .map { entry in
                    Row(
                        id: entry.id,
                        day: DateOnly(key: entry.occurredDay),
                        amount: Money(cents: entry.amount),
                        note: entry.note,
                        accountName: entry.account?.name,
                        iconName: entry.category?.iconName ?? "questionmark.circle",
                        colorHex: entry.category?.colorHex ?? "#9E9E9E"
                    )
                }
            errorMessage = nil
        } catch {
            errorMessage = "读取账目失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }
    }

    /// 这条账目是否属于本次下钻的分类。
    ///
    /// - 普通分类：按 id 精确匹配；
    /// - 未分类：`category == nil`；
    /// - 合并桶「其他」：用 `mergedCategoryIDs` 精确筛（由计算器在合并时记录下来），
    ///   而不是"显示全部支出"——那样用户点「其他」看到和"全部"一样的内容会以为坏了。
    private func matches(_ entry: LedgerEntry) -> Bool {
        if isMerged {
            guard !mergedCategoryIDs.isEmpty else { return false }
            guard let id = entry.category?.id else { return false }
            return mergedCategoryIDs.contains(id)
        }
        if let categoryID {
            return entry.category?.id == categoryID
        }
        return entry.category == nil
    }

    /// 合并桶的说明文案。
    var subtitleHint: String? {
        guard isMerged else { return nil }
        return mergedCategoryIDs.isEmpty
            ? "这些小分类没有可显示的记录"
            : "包含 \(mergedCategoryIDs.count) 个小分类的记录"
    }
}
