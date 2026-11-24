//
//  HomeHeaderCards.swift
//  一账 / Features / Ledger
//
//  职责：账本首页顶部的两块——「本月支出概览卡」与「今日速览条」（T08）。
//
//  两处刻意的排版决定：
//  ① **概览卡的数字只出现一次**：`¥3,482.50` 用 40pt 大字，收入/结余降级到 12pt 同行。
//     三个数字平铺会让"本月支出"和"结余"看起来同等重要，
//     而用户打开账本时想知道的第一件事永远是"这个月花了多少"。
//  ② **速览条整个条目为空就不显示**：留一个 44pt 的空白条比不留更让人困惑
//     （"是不是没加载出来？"）。这条由 `GlanceModel.isEmpty` 判定，视图不做业务判断。
//
//  概览卡可点 → 统计页（T19）。T19 未落地前推到 `StatisticsPlaceholderView`：
//  **不做死按钮**——点了要跳转，跳过去要能看懂"这里将来是什么"。
//

import SwiftUI

// MARK: - 月度概览卡

/// 本月支出概览卡。
struct MonthOverviewCard: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 本月合计。
    let summary: MonthSummary

    /// 与上月的对比。
    let comparison: ExpenseComparison

    /// 月份标题（「2026年11月」）。
    let monthTitle: String

    /// 点卡片（进统计页）。
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header

            MoneyText(
                amount: summary.expense,
                tone: .expense,
                emphasis: .large,
                showsSign: false
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            inlineMetrics

            comparisonLine
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(onTap == nil ? AccessibilityTraits() : .isButton)
        .accessibilityIdentifier("ledger.overviewCard")
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("本月支出")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: Theme.Spacing.xs)

            Text(monthTitle)
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()

            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// 收入 · 结余（同一行，小字，不与主数字抢视线）。
    /// 「收入 … · 结余 …」。
    ///
    /// AX 字号下这一行会挤成三行互相压字（T24 截图实测），
    /// 所以无障碍字号时拆成上下两行、去掉中间的分隔点。
    private var inlineMetrics: some View {
        let isAccessibility = dynamicTypeSize.isAccessibilitySize
        let layout = isAccessibility
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.xxs))

        return layout {
            HStack(spacing: Theme.Spacing.xxs) {
                Text("收入")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                Text(summary.income.formatted())
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if !isAccessibility {
                Text("·")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: Theme.Spacing.xxs) {
                Text("结余")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                Text(summary.balance.formatted())
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if !isAccessibility {
                Spacer(minLength: 0)
            }
        }
    }

    /// 较上月。
    ///
    /// 颜色语义：**支出变多是坏事 → 红**，变少是好事 → 绿（PRD 3.4）。
    /// 这与"支出金额本身用主文本色"不冲突——那个是金额，这个是趋势评价。
    private var comparisonLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(comparisonColor)
                .accessibilityHidden(true)

            Text(comparison.text)
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(comparisonColor)

            Spacer(minLength: 0)
        }
    }

    private var iconName: String {
        switch comparison.direction {
        case .increase: return "arrow.up.right"
        case .decrease: return "arrow.down.right"
        case .flat, .unavailable: return "minus"
        }
    }

    private var comparisonColor: Color {
        switch comparison.direction {
        case .increase: return Theme.Semantic.danger
        case .decrease: return Theme.Semantic.income
        case .flat: return .secondary
        case .unavailable: return Color.secondary.opacity(0.6)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = [
            "\(monthTitle)支出\(summary.expense.accessibilityText)",
            "收入\(summary.income.accessibilityText)",
            "结余\(summary.balance.accessibilityText)",
            comparison.text
        ]
        if onTap != nil { parts.append("轻点查看统计") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 今日速览

/// 今日速览条：待办 + 近期订阅。两项都为空时**整个视图不渲染**。
struct TodayGlanceStrip: View {

    let glance: GlanceModel

    /// 点「待办」。
    var onTapTodo: (() -> Void)?

    /// 点「订阅」。
    var onTapSubscription: (() -> Void)?

    var body: some View {
        if glance.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: Theme.Spacing.xs) {
                if glance.todoCount > 0 {
                    chip(
                        iconName: "checklist",
                        text: "\(glance.todoCount) 件待办",
                        action: onTapTodo
                    )
                }

                if glance.subscriptionCount > 0 {
                    chip(
                        iconName: "arrow.triangle.2.circlepath",
                        text: "\(glance.subscriptionCount) 笔订阅 \(glance.subscriptionTotal.conciseText)",
                        action: onTapSubscription
                    )
                }

                Spacer(minLength: 0)
            }
            // 整条高度上限 44pt：它只是一个"提示条"，不该比一行账目更抢眼
            .frame(maxHeight: Theme.minimumTapSize)
            .accessibilityIdentifier("ledger.glanceStrip")
        }
    }

    private func chip(iconName: String, text: String, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)

                Text(text)
                    .font(Theme.Typography.captionStrong)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Semantic.cardBackground)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.minimumTapSize)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - 统计页占位

/// 统计页占位（T19 会替换成真正的图表页）。
///
/// 存在的唯一理由：概览卡必须可点，而点了不能没反应。
/// 所以它至少要说清"这里将来有什么"，而不是一个空白页。
// MARK: - 预览

#Preview("概览卡与速览条") {
    VStack(spacing: Theme.Spacing.md) {
        MonthOverviewCard(
            summary: MonthSummary(expense: Money(cents: 348_250), income: Money(cents: 1_200_000)),
            comparison: ExpenseComparison(direction: .increase, magnitudeThousandths: 124),
            monthTitle: "2026年11月",
            onTap: {}
        )

        TodayGlanceStrip(
            glance: GlanceModel(
                todoCount: 2,
                subscriptionCount: 3,
                subscriptionTotal: Money(cents: 54_300)
            ),
            onTapTodo: {},
            onTapSubscription: {}
        )

        MonthOverviewCard(
            summary: MonthSummary(expense: Money(cents: 0), income: Money(cents: 0)),
            comparison: .unavailable,
            monthTitle: "2026年10月",
            onTap: {}
        )
    }
    .padding()
    .background(Theme.Semantic.pageBackground)
}
