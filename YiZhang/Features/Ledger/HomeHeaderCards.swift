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
//  ③ **待确认是"补充行"，不是第二个大数字**（V1.1 F-SUB-13）：`pending` 已计入月度合计，
//     所以卡上的大数字不用改（Q1）。有待确认时在「较上月」下面补一行
//     「含待确认 3 笔 ¥68.00 ›」，把它做成独立可点区域——整卡手势只覆盖上半部分，
//     否则点这一行会连带跳去统计页（嵌套 Button 与祖先 onTapGesture 会同时命中）。
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

    /// 待确认的笔数（V1.1 F-SUB-13）。`0` = 不渲染第二行。
    ///
    /// 用 `var` + 默认值而不是 `let`：`let` 带默认值的存储属性会被从 memberwise init
    /// 里剔除，既有构造点（首页 / 预览）就再也传不进来了。
    var pendingCount: Int = 0

    /// 待确认的金额合计。**只用于展示"其中有多少还没核对"**，不参与主数字（Q1）。
    var pendingAmount: Money = .zero

    /// 点「含待确认 N 笔」（进账本并套 `pendingOnly` 筛选）。
    var onTapPending: (() -> Void)?

    /// 点卡片（进统计页）。
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryBlock
                // 内边距放在**可点区域里面**：整张卡（含四边留白）就是点击区，
                // 与 V1.0 的 `.contentShape` + 整卡手势完全等价。
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, showsPendingLine ? Theme.Spacing.xs : Theme.Spacing.md)
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(accessibilityText))
                .accessibilityAddTraits(onTap == nil ? AccessibilityTraits() : .isButton)
                .accessibilityIdentifier("ledger.overviewCard")

            if showsPendingLine {
                pendingLine
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
    }

    // MARK: - 子视图

    /// 上半部分：标题 / 大金额 / 收入结余 / 较上月。
    private var summaryBlock: some View {
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
    }

    private var showsPendingLine: Bool { pendingCount > 0 }

    /// 「含待确认 3 笔 ¥68.00 ›」。
    ///
    /// 为什么单独一行、而不是把待确认混进大数字里：PRD 2.3-1 规定 pending **计入**月度合计，
    /// 所以大数字本来就是"含待确认"的（Q1）。这一行补的是"这里面有多少还没核对"，
    /// 是一个补充说明，不是第二个金额。把它做成独立可点行，用户想核对时才点。
    private var pendingLine: some View {
        Button {
            onTapPending?()
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Text("含待确认 \(pendingCount) 笔 \(pendingAmount.formatted())")
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Semantic.pending)
            .frame(minHeight: Theme.minimumTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTapPending == nil)
        .accessibilityLabel(Text("含待确认 \(pendingCount) 笔，共 \(pendingAmount.accessibilityText)，轻点查看"))
        .accessibilityIdentifier("ledger.overviewCard.pending")
    }

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
        if showsPendingLine {
            parts.append("含待确认 \(pendingCount) 笔 \(pendingAmount.accessibilityText)")
        }
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
            pendingCount: 3,
            pendingAmount: Money(cents: 6800),
            onTapPending: {},
            onTap: {}
        )

        TodayGlanceStrip(
            glance: GlanceModel(
                todoCount: 2,
                subscriptionCount: 3,
                subscriptionTotal: Money(cents: 54_300),
                pendingCount: 3,
                pendingAmount: Money(cents: 6800)
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
