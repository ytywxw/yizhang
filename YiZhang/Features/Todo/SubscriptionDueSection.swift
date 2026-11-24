//
//  SubscriptionDueSection.swift
//  一账 / Features / Todo
//
//  职责：待办页顶部那张「订阅扣费」只读分组（T16）。
//
//  ## 为什么它是只读、且必须折叠
//
//  ① **只读**：它来自 `SubscriptionOverview.upcoming(...)` 的实时派生（D4），
//     不是 `Todo`。它没有勾选框——用户没有"办"这件事的动作可做，钱是系统自动扣的。
//     给它一个勾选框，用户会以为自己能"取消这次扣费"，那是谎。
//  ② **默认折叠**：它每天都会有几条，展开会把"今天要办的事"挤到屏幕外。
//  ③ **不计入「今天要办 N 件」**（R-MIX-3）：那个数字要回答"我要动手几件事"。
//  ④ **不生成任何账目**：本组件只读 `DueItem`，不持有 `AppEnvironment`，
//     从类型上就写不出账目来。
//

import SwiftUI

/// 订阅扣费只读分组。
struct SubscriptionDueSection: View {

    let items: [SubscriptionOverview.DueItem]
    let today: DateOnly
    /// 是否展开（由外部持有，默认 `false`）。
    let isExpanded: Bool
    /// 「约 ¥X」的合计。
    let total: Money
    let onToggle: () -> Void
    /// 点某一条 → 订阅详情。
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        row(item)
                        if index < items.count - 1 {
                            Divider()
                                .opacity(0.4)
                                .padding(.leading, Theme.Spacing.md)
                        }
                    }

                    hint
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(Theme.Semantic.cardBackground)
                )
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
        .accessibilityIdentifier("todo.dueSection")
    }

    // MARK: - 头部

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("订阅扣费 \(items.count) 笔")
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(.secondary)

                Text("约 \(MoneyText.wholeYuanText(total))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: Theme.Spacing.xs)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(minHeight: Theme.minimumTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("订阅扣费 \(items.count) 笔，约 \(MoneyText.wholeYuanText(total))"))
        .accessibilityHint(Text(isExpanded ? "收起" : "展开"))
        .accessibilityIdentifier("todo.dueSection.toggle")
    }

    // MARK: - 行

    private func row(_ item: SubscriptionOverview.DueItem) -> some View {
        Button {
            onSelect(item.subscriptionID)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                // 没有勾选框：这里没有"办"的动作（见文件头 ①）
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(item.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(dueText(item))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(item.isOverdue(on: today) ? Theme.Semantic.danger : Color.secondary)
                }

                Spacer(minLength: Theme.Spacing.xs)

                Text(MoneyText.compactString(item.amount))
                    .font(Theme.Typography.amountSmall)
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(minHeight: Theme.minimumTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(item.name)，\(dueText(item))，\(MoneyText.compactString(item.amount))"))
    }

    private func dueText(_ item: SubscriptionOverview.DueItem) -> String {
        if item.isOverdue(on: today) { return "已过期 \(item.day.displayString)" }
        if item.day == today { return "今天扣费" }
        let days = item.day.key - today.key
        return "\(item.day.displayString)（\(days) 天后）"
    }

    private var hint: some View {
        Text("自动扣费，不需要你动手。点一条可以改订阅。")
            .font(Theme.Typography.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xs)
            .accessibilityHidden(true)
    }
}

// MARK: - 预览

#Preview("订阅扣费分组") {
    let today = DateOnly(key: 20261121)
    return VStack(spacing: Theme.Spacing.md) {
        SubscriptionDueSection(
            items: [
                SubscriptionOverview.DueItem(
                    subscriptionID: UUID(),
                    name: "视频会员",
                    day: today.adding(days: 4),
                    amount: Money(cents: 2500)
                ),
                SubscriptionOverview.DueItem(
                    subscriptionID: UUID(),
                    name: "云盘",
                    day: today,
                    amount: Money(cents: 12000)
                )
            ],
            today: today,
            isExpanded: true,
            total: Money(cents: 14500),
            onToggle: {},
            onSelect: { _ in }
        )
        SubscriptionDueSection(
            items: [],
            today: today,
            isExpanded: false,
            total: .zero,
            onToggle: {},
            onSelect: { _ in }
        )
    }
    .padding(.vertical, Theme.Spacing.md)
    .background(Theme.Semantic.pageBackground)
}
