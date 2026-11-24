//
//  SubscriptionOverviewCards.swift
//  一账 / Features / Subscription
//
//  职责：订阅页顶部的两张卡——「总览卡」与「未来 30 天扣费时间轴」（PRD 4.4 / 4.5）。
//
//  两条展示纪律：
//  ① 每月固定支出是**折算值**，必须标注「约」。它把年付 ÷12、周付 ×4.345 摊平，
//     不标"约"会让用户拿它跟账单逐分对照，然后认为数据错了。
//  ② 时间轴可以收起，但**合计行始终跟着可见项**：收起时卡片头部显示"未来 30 天共 ¥X"，
//     展开后在列表底部再显示一次——用户在任何状态下都能看到这个数字。
//
//  本文件不做任何业务计算：所有数字来自 `SubscriptionListViewModel.OverviewModel`。
//

import SwiftUI

// MARK: - 总览卡

/// 订阅总览卡：每月固定支出 / 年度总成本 / 未来 30 天合计。
struct SubscriptionOverviewCard: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let overview: SubscriptionListViewModel.OverviewModel

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            headline

            Divider()
                .opacity(0.5)

            metricRow(
                title: "年度订阅总成本",
                detail: nil,
                amount: overview.yearlyCost
            )

            metricRow(
                title: "未来 30 天",
                detail: overview.upcomingCount > 0 ? "\(overview.upcomingCount) 笔" : nil,
                amount: overview.upcomingTotal
            )
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// 首行：标签 + 「约 ¥234」（两者拼成**一个** `Text`）。
    ///
    /// 为什么拼成一个 `Text` 而不是两个 `Text` 放在 `HStack` 里：
    /// `HStack` 里的元素会被可用宽度重新分配位置，「约」和数字之间会莫名其妙裂开一道缝；
    /// 而 `Text + Text` 是一个排版单元，中间不可能被撑开——「约」永远紧贴数字，
    /// 同时保留"约"用 12pt、数字用 28pt"的字号差。
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text("每月固定支出")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Spacer(minLength: Theme.Spacing.xs)

            // 折算值必须标"约"，并且只显示整元——`¥234.00` 会给出假的精确感
            (
                Text("约 ")
                    .font(Theme.Typography.caption)
                    .foregroundColor(.secondary)
                + Text(MoneyText.wholeYuanText(overview.monthlyFixedCost))
                    .font(Theme.Typography.amountMedium)
                    .foregroundColor(.primary)
            )
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel(Text("约\(overview.monthlyFixedCost.accessibilityText)"))
        }
    }

    /// 一行指标（标题 + 可选细节 + 右侧金额）。
    ///
    /// AX 字号下并排会把金额挤成「¥2808\n.00」并压到标题上（T24 截图实测），
    /// 所以无障碍字号时改成「标题一行、金额一行」。
    private func metricRow(title: String, detail: String?, amount: Money) -> some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        let layout = isAccessibility
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.xs))

        return layout {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)

                if let detail {
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                if !isAccessibility {
                    Spacer(minLength: Theme.Spacing.xs)
                }
            }

            MoneyText(amount: amount, tone: .neutral, emphasis: .body)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        parts.append("每月固定支出约\(overview.monthlyFixedCost.accessibilityText)")
        parts.append("年度订阅总成本\(overview.yearlyCost.accessibilityText)")
        parts.append("未来 30 天共\(overview.upcomingTotal.accessibilityText)")
        return parts.joined(separator: "，")
    }
}

// MARK: - 时间轴

/// 未来 30 天扣费时间轴（可折叠）。
struct SubscriptionTimelineCard: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let items: [SubscriptionOverview.DueItem]
    let total: Money
    let today: DateOnly
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            if isExpanded {
                if items.isEmpty {
                    emptyState
                } else {
                    ForEach(items, id: \.self) { item in
                        divider
                        row(for: item)
                    }
                    divider
                    footer
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text("未来 30 天扣费")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: Theme.Spacing.xs)

                if !isExpanded {
                    // 收起时也保留合计（用户在任何状态都能看到这个数字）
                    Text("共 \(total.formatted())")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .frame(minHeight: Theme.minimumTapSize)
            .padding(.horizontal, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isExpanded ? "收起未来 30 天扣费" : "展开未来 30 天扣费"))
    }

    private func row(for item: SubscriptionOverview.DueItem) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm))

        return layout {
            HStack(spacing: Theme.Spacing.xs) {
                Text(item.day.displayString)
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(item.isOverdue(on: today) ? Theme.Semantic.danger : .secondary)
                    // AX 下日期不再固定 64pt 宽（那个宽度放不下放大后的「11月18日」）
                    .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 0 : 64,
                           alignment: .leading)

                if dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: Theme.Spacing.xs)
                    if item.isOverdue(on: today) {
                        Text("已到期")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                    }
                }
            }

            Text(item.name)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Theme.Spacing.xs)

                if item.isOverdue(on: today) {
                    Text("已到期")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                }
            }

            MoneyText(amount: item.amount, tone: .expense, emphasis: .body)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("未来 30 天共")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.xs)
            MoneyText(amount: total, tone: .expense, emphasis: .body)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("接下来 30 天没有扣费")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Divider()
            .opacity(0.4)
            .padding(.leading, Theme.Spacing.md)
    }
}

// MARK: - 预览

#Preview("订阅总览卡") {
    SubscriptionOverviewPreview()
}

/// 预览专用容器（把造数据放在 View 里，避免 `#Preview` 闭包里写语句）。
private struct SubscriptionOverviewPreview: View {

    private let today = DateOnly(year: 2026, month: 11, day: 21) ?? .zero

    private var snapshots: [SubscriptionSnapshot] {
        [
            SubscriptionSnapshot(
                id: UUID(), name: "视频会员", amount: 2500, nextBillingDay: 20261125,
                cycleUnit: .month, cycleValue: 1, anchorDay: 25
            ),
            SubscriptionSnapshot(
                id: UUID(), name: "云盘", amount: 12000, nextBillingDay: 20261220,
                cycleUnit: .year, cycleValue: 1, anchorDay: 20
            ),
            SubscriptionSnapshot(
                id: UUID(), name: "健身房", amount: 19900, nextBillingDay: 20261118,
                cycleUnit: .month, cycleValue: 1, anchorDay: 18
            )
        ]
    }

    var body: some View {
        let upcoming = SubscriptionOverview.upcoming(snapshots, today: today)
        VStack(spacing: Theme.Spacing.md) {
            SubscriptionOverviewCard(
                overview: SubscriptionListViewModel.makeOverview(snapshots: snapshots, today: today)
            )
            SubscriptionTimelineCard(
                items: upcoming,
                total: SubscriptionOverview.upcomingTotal(upcoming),
                today: today,
                isExpanded: .constant(true)
            )
        }
        .padding()
        .background(Theme.Semantic.pageBackground)
    }
}
