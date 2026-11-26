//
//  StatisticsEmptyStates.swift
//  一账 / Features / Statistics
//
//  职责：三张图各自的空态（T19）。
//
//  **为什么不做"空坐标系"**：空坐标系传达的是"有数据但都是 0"，而真实情况是
//  "这个范围没有记录"。两者对用户的指示完全不同——前者让人以为数据丢了。
//  所以每张图在数据为空时整体换成一句话 + 一个可执行的动作（去记一笔）。
//

import SwiftUI

/// 图表卡片外壳（标题 + 副标题 + 内容 + 空态）。
struct StatsCard<Content: View>: View {

    let title: String
    var subtitle: String?
    var isEmpty: Bool = false
    /// 空态文案。
    var emptyMessage: String = "还没有数据"
    /// 空态图标。
    var emptyIcon: String = "chart.bar"

    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isEmpty {
                emptyBody
            } else {
                content()
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var emptyBody: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: emptyIcon)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(emptyMessage)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.empty")
    }
}

// MARK: - 三张图各自的空态文案

/// 空态文案集中在一处：改文案不需要翻三个视图文件，也方便统一语气。
enum StatisticsEmptyCopy {

    /// 月度对比：整段没有任何数据。
    static let monthly = "最近 6 个月还没有收支记录，记几笔就能看到趋势。"

    /// 分类占比：当前范围没有支出 / 收入（两个口径各自为空时都要说清楚）。
    static func category(rangeTitle: String, metric: StatisticsMetric = .expense) -> String {
        "\(rangeTitle)还没有\(metric.displayName)记录，\(metric.displayName)分类占比会显示在这里。"
    }

    /// 累计趋势：本月没有该口径的记录。
    static func trend(metric: StatisticsMetric) -> String {
        "这个月还没有\(metric.displayName)记录，\(metric.displayName)趋势会显示在这里。"
    }

    /// 同比环比（V1.1 F-ACC-16）：当期与两个基线都没有金额。
    ///
    /// 措辞刻意不说"没有数据"：用户可能刚记了账但从没记过上月/去年的，
    /// 那种情况下卡片不会空（会显示「新增」+「去年同月无数据」），所以走到这条文案
    /// 就只有一种可能——这个范围真的什么都没有。
    static func comparison(rangeTitle: String, metric: StatisticsMetric) -> String {
        "\(rangeTitle)还没有\(metric.displayName)记录，\(metric.displayName)同比环比会显示在这里。"
    }

    /// 账户构成：这个范围没有该口径的记录（或者记录全都没有账户、也没有金额）。
    static func accountShares(rangeTitle: String, metric: StatisticsMetric) -> String {
        "\(rangeTitle)还没有\(metric.displayName)记录，\(metric.displayName)按账户的分布会显示在这里。"
    }

    /// 空态标题（页面级，当月完全没有数据时）。
    static func pageTitle(rangeTitle: String) -> String {
        "\(rangeTitle)还没有记录"
    }

    static let pageMessage = "记一笔之后，这里会有收支对比、分类占比和累计趋势。"
}
