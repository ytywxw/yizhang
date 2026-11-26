//
//  ComparisonCards.swift
//  一账 / Features / Statistics
//
//  职责：统计页后两张卡——「同比环比」与「账户构成」（V1.1 F-ACC-16）。
//
//  ## 三个刻意的取舍
//
//  ① **句子在这一层，不在值类型里**。`PeriodComparison` 只知道数值与方向，
//     而"去年同月无数据"还是"去年同期无数据"取决于当前是哪一档——那是视图的知识。
//     所以全部文案集中在 `ComparisonCopy`，一个字都不放进 Domain。
//  ② **区间小字是必显项，不是装饰**。「同比 ▲16.9%」如果不说清"和哪 20 天比"，
//     用户会拿"去年整月"的心智去读一个"去年同月 1–20 日"的数字，
//     于是每次看到统计页都觉得"和首页对不上"。`detailText` 因此不接受"没有区间"这种入参。
//  ③ **不可下钻的行不给 chevron**。「未知账户」的账目无法用 `accountIDs` 表达
//     （`nil` 表达不了），硬凑一个空集合会被判成"不过滤"，点进去看到全部账目——
//     那比"点不动"更糟：用户会以为筛选坏了。
//

import SwiftUI

// MARK: - 文案

/// 同比 / 环比的全部文案（纯函数，便于单测）。
enum ComparisonCopy {

    /// 两格对比分别是哪一格。
    enum Slot: Hashable, Sendable {
        case yearOverYear
        case monthOverMonth
    }

    /// 格子左上角的标签。
    static func slotLabel(_ slot: Slot) -> String {
        switch slot {
        case .yearOverYear: return "同比"
        case .monthOverMonth: return "环比"
        }
    }

    /// 主数字上方的说明：这一期到底是"整月"还是"到某日"。
    static func currentCaption(_ range: StatisticsRange) -> String {
        switch range {
        case .thisMonth: return "本月至今"
        case .lastMonth: return "上月整月"
        case .thisYear: return "本年至今"
        }
    }

    /// 基线那一格的称呼。
    ///
    /// 上月档的"上一段等长区间"是**上上月整月**，不是"上月同期"——
    /// 同一个词在两档里指不同区间的，只有这里一处，所以用档位而不是固定词。
    static func baselineCaption(slot: Slot, range: StatisticsRange) -> String {
        switch slot {
        case .yearOverYear:
            return range == .thisYear ? "去年同期" : "去年同月"
        case .monthOverMonth:
            return range == .thisMonth ? "上月同期" : "上上月"
        }
    }

    /// 基线区间一笔账都没有时的说明（PRD 3.3-4）。
    ///
    /// 本年档说「去年同期」而不是「去年同月」：年档比的是"去年 1 月 1 日–同一日"，
    /// 说成"同月"会让用户以为只比了某一个月。
    static func emptyBaselineText(slot: Slot, range: StatisticsRange) -> String {
        switch slot {
        case .yearOverYear:
            return range == .thisYear ? "去年同期无数据" : "去年同月无数据"
        case .monthOverMonth:
            return range == .thisMonth ? "上月无数据" : "上上月无数据"
        }
    }

    /// 右侧的变化文案。
    ///
    /// 五条分支逐条对应任务书 §1，**不要合并**：
    /// - `.increase` → `▲16.9%`
    /// - `.decrease` → `▼8.1%`
    /// - `.flat` 且当期 > 0 → 「持平」（两期金额完全相等）
    /// - `.flat` 且当期 == 0 → 「—」（两期都空；说"持平"等于说"没变化"，是造假）
    /// - `.unavailable`（基线为 0）→ 当期 > 0 时「新增」，当期也为 0 时「—」
    static func changeText(_ comparison: PeriodComparison) -> String {
        switch comparison.direction {
        case .increase:
            return "▲\(PeriodComparison.percentText(comparison.magnitudeThousandths))"
        case .decrease:
            return "▼\(PeriodComparison.percentText(comparison.magnitudeThousandths))"
        case .flat:
            return comparison.current.cents > 0 ? "持平" : "—"
        case .unavailable:
            return comparison.current.cents > 0 ? "新增" : "—"
        }
    }

    /// 基线那一格的金额：基线没有账目时给「—」而不是「¥0.00」。
    ///
    /// 「¥0.00」会被读成"那段时间一笔都没花"，而 `.unavailable` 的含义恰恰是
    /// "那段时间一笔记录都没有"——两者对用户的指示完全不同。
    static func baselineAmountText(_ comparison: PeriodComparison) -> String {
        comparison.isAvailable ? comparison.baseline.formatted() : "—"
    }

    /// 格子下方的小字：正常情况给**实际区间**，基线为空时给"无数据"。
    ///
    /// 「新增」与「去年同月无数据」**不是互斥的两件事**：前者是"变化方向无从计算"，
    /// 后者是"为什么无从计算"。只显示前者，用户会以为算法坏了；
    /// 只显示后者，用户看不出当期到底比去年同期多还是少。
    static func detailText(
        slot: Slot,
        range: StatisticsRange,
        comparison: PeriodComparison,
        bounds: ClosedRange<Int32>,
        today: DateOnly
    ) -> String {
        guard comparison.isAvailable else { return emptyBaselineText(slot: slot, range: range) }
        return rangeText(bounds, today: today)
    }

    /// 日键区间 → 「去年 11 月 1–20 日」/「11 月」/「去年 1 月 1 日–11 月 20 日」。
    static func rangeText(_ bounds: ClosedRange<Int32>, today: DateOnly) -> String {
        let start = DateOnly(key: bounds.lowerBound)
        let end = DateOnly(key: bounds.upperBound)
        guard start.isValid, end.isValid else { return "" }
        let prefix = yearPrefix(start.year, today: today)

        if start.monthKey == end.monthKey {
            let lastDay = DateOnly.daysInMonth(year: start.year, month: start.month)
            if start.day == 1 && end.day == lastDay {
                return "\(prefix)\(start.month) 月"
            }
            if start.day == end.day {
                return "\(prefix)\(start.month) 月 \(start.day) 日"
            }
            return "\(prefix)\(start.month) 月 \(start.day)–\(end.day) 日"
        }
        // 本年档的同比会跨月（去年 1/1 … 去年同一日）
        return "\(prefix)\(start.month) 月 \(start.day) 日–\(end.month) 月 \(end.day) 日"
    }

    /// 「去年 」/「」/「2024 年 」——只在这里判一次。
    private static func yearPrefix(_ year: Int, today: DateOnly) -> String {
        switch today.year - year {
        case 0: return ""
        case 1: return "去年 "
        default: return "\(year) 年 "
        }
    }

    /// 一格对比的 VoiceOver 朗读稿。
    static func chipAccessibilityText(
        slot: Slot,
        range: StatisticsRange,
        comparison: PeriodComparison,
        detail: String
    ) -> String {
        let label = slotLabel(slot)
        let caption = baselineCaption(slot: slot, range: range)
        let baseline = comparison.isAvailable ? comparison.baseline.formatted() : "没有数据"
        return "\(label)，\(caption) \(baseline)，\(changeText(comparison))。\(detail)"
    }
}

// MARK: - 同比环比卡（内容）

/// 同比环比卡的内容区（外壳仍是 `StatsCard`）。
struct ComparisonCardContent: View {

    let comparison: StatisticsComparison
    let bounds: PeriodComparisonBounds
    let range: StatisticsRange
    let metric: StatisticsMetric
    let today: DateOnly

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            mainAmount

            VStack(spacing: Theme.Spacing.xs) {
                chip(slot: .yearOverYear, comparison: comparison.yoy, bounds: bounds.yearOverYear)
                // `mom == nil` 时整格不出现（本年档）：给一个 `.flat` 占位会凭空多出
                // 一行「环比 持平」，而那一行背后的数据根本不存在。
                if let mom = comparison.mom, let momBounds = bounds.monthOverMonth {
                    chip(slot: .monthOverMonth, comparison: mom, bounds: momBounds)
                }
            }
        }
    }

    private var mainAmount: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(ComparisonCopy.currentCaption(range))
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            Text(comparison.current.formatted())
                .font(Theme.Typography.amountMedium)
                .foregroundStyle(Theme.Semantic.color(for: metric.entryType))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func chip(
        slot: ComparisonCopy.Slot,
        comparison: PeriodComparison,
        bounds: ClosedRange<Int32>
    ) -> some View {
        let detail = ComparisonCopy.detailText(
            slot: slot,
            range: range,
            comparison: comparison,
            bounds: bounds,
            today: today
        )

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(ComparisonCopy.slotLabel(slot))
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Semantic.pageBackground))

                Text(
                    "\(ComparisonCopy.baselineCaption(slot: slot, range: range)) "
                        + ComparisonCopy.baselineAmountText(comparison)
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: Theme.Spacing.xs)

                // 变化文案是这一格的主角：金额被挤时可以截断，它不能被挤掉
                Text(ComparisonCopy.changeText(comparison))
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(changeColor(comparison))
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Semantic.pageBackground.opacity(0.6))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            ComparisonCopy.chipAccessibilityText(
                slot: slot,
                range: range,
                comparison: comparison,
                detail: detail
            )
        ))
    }

    /// 涨跌不套红绿：颜色只表达"支出/收入"（`Theme.Semantic` 纪律），
    /// 方向已经由 ▲ / ▼ 表达，重复上色会让"支出涨了"看起来像报警。
    private func changeColor(_ comparison: PeriodComparison) -> Color {
        switch comparison.direction {
        case .increase, .decrease: return .primary
        case .flat, .unavailable: return .secondary
        }
    }
}

// MARK: - 账户构成卡（内容）

/// 账户构成卡的内容区：账户名 + 金额 + 占比 + 一条占比条。
struct AccountShareCardContent: View {

    let shares: [AccountShare]
    let metric: StatisticsMetric
    let title: (AccountShare) -> String
    let isArchived: (AccountShare) -> Bool
    let canDrill: (AccountShare) -> Bool
    var onSelect: (AccountShare) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(shares) { share in
                row(share)
            }
        }
    }

    /// 可下钻的行才是 `Button`；不可下钻的行连 chevron 都不给。
    @ViewBuilder
    private func row(_ share: AccountShare) -> some View {
        if canDrill(share) {
            Button {
                onSelect(share)
            } label: {
                rowBody(share, showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stats.account.row")
        } else {
            rowBody(share, showsChevron: false)
                .accessibilityIdentifier("stats.account.row.static")
        }
    }

    private func rowBody(_ share: AccountShare, showsChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title(share))
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if isArchived(share) {
                    Text("已归档")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.xs)

                Text(share.amount.formatted())
                    .font(Theme.Typography.amountSmall)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("占 \(share.percent)%")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 52, alignment: .trailing)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }

            bar(share)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .frame(minHeight: Theme.minimumTapSize)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel(share, showsChevron: showsChevron)))
    }

    /// 占比条：轨道用页面底色，填充用该口径的金额色。
    ///
    /// 用 `GeometryReader`（而不是 `containerRelativeFrame`）是因为这张卡在
    /// `LazyVStack` 里、又可能被 AX 字号撑高，相对容器的解析结果不稳定；
    /// 自己拿宽度算是最没有惊喜的做法。
    private func bar(_ share: AccountShare) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Semantic.pageBackground)
                Capsule()
                    .fill(fillColor(share))
                    .frame(width: fillWidth(ratio: share.ratio, available: proxy.size.width))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func fillColor(_ share: AccountShare) -> Color {
        // 合并桶用次级色：它不是"某个账户"，不该和真实账户一样抢眼
        share.isMerged ? Color.secondary : Theme.Semantic.color(for: metric.entryType)
    }

    private func fillWidth(ratio: Double, available: CGFloat) -> CGFloat {
        guard ratio > 0, available > 0 else { return 0 }
        let clamped = min(max(ratio, 0), 1)
        // 占比极小时留 3pt：0.4% 的账户也应该有一道可见的痕迹，而不是完全空白
        return max(available * CGFloat(clamped), 3)
    }

    private func accessibilityLabel(_ share: AccountShare, showsChevron: Bool) -> String {
        var parts = [title(share), share.amount.formatted(), "占 \(share.percent)%"]
        if isArchived(share) { parts.append("已归档") }
        if !showsChevron { parts.append("没有可查看的明细") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 下钻：某个账户的账目列表

/// 账户账目列表（从账户构成卡下钻进入）。
///
/// 形态与 `CategoryEntriesView` 一致（轻量只读列表，不走账本页那套筛选状态机），
/// 差异只有两处：① 多了口径（支出/收入），否则点「收入」卡进来会看到支出；
/// ② 筛的是 `accountIDs` 而不是分类。
///
/// **`accountIDs` 为空时列表为空，而不是"全部账目"**：
/// 空集合在 `EntryFilter` 里会被判成"不过滤"，那样用户点「其他」会看到整月账单。
struct AccountEntriesView: View {

    @Environment(AppEnvironment.self) private var environment

    let accountTitle: String
    let range: StatisticsRange
    let today: DateOnly
    let metric: StatisticsMetric
    /// 要包含的账户 id（「其他」时是 `mergedAccountIDs`，真实账户时只有一个）。
    let accountIDs: Set<UUID>
    /// 是否是「其他」桶（决定空态措辞）。
    let isMerged: Bool

    @State private var rows: [Row] = []
    @State private var errorMessage: String?

    /// 一行账目（只读快照）。
    struct Row: Identifiable, Hashable {
        let id: UUID
        let day: DateOnly
        let amount: Money
        let note: String
        let categoryName: String
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
                    Text(emptyMessage)
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
                                    .padding(.leading, Theme.Spacing.md)
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
        .navigationTitle(accountTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .task(id: environment.dataVersion) { load() }
        .accessibilityIdentifier("stats.accountEntries")
    }

    private var emptyMessage: String {
        isMerged
            ? "这些小账户在这个范围内没有可显示的记录"
            : "这个账户在这个范围内没有\(metric.displayName)记录"
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(row.note.isEmpty ? row.categoryName : row.note)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: Theme.Spacing.xxs) {
                    Text(row.day.displayString)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                    Text(row.categoryName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Theme.Spacing.xs)

            Text(row.amount.formatted())
                .font(Theme.Typography.amountSmall)
                .foregroundStyle(Theme.Semantic.color(for: metric.entryType))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: Theme.minimumTapSize)
    }

    // MARK: 取数

    private func load() {
        // 空集合不查：`accountIDs.isEmpty` 意味着"没有可筛的账户"，
        // 若照常取全部账目再筛，会筛出一条都没有；但若有人把这段改成"空则不过滤"，
        // 用户就会看到整月账单。所以提前 return，把意图写在代码里。
        guard !accountIDs.isEmpty else {
            rows = []
            errorMessage = nil
            return
        }

        do {
            let bounds = StatisticsCalculator.dayRange(of: range, today: today)
            let models = try environment.readContext
                .fetch(QueryDescriptors.allEntries())
                .filter { entry in
                    guard entry.deletedAt == nil,
                          entry.typeRaw == metric.entryType.raw,
                          entry.amount > 0,
                          bounds.contains(entry.occurredDay) else { return false }
                    guard let accountID = entry.account?.id else { return false }
                    return accountIDs.contains(accountID)
                }

            rows = models
                .sorted { $0.occurredDay > $1.occurredDay }
                .map { entry in
                    Row(
                        id: entry.id,
                        day: DateOnly(key: entry.occurredDay),
                        amount: Money(cents: entry.amount),
                        note: entry.note,
                        categoryName: entry.category?.name ?? "未分类"
                    )
                }
            errorMessage = nil
        } catch {
            errorMessage = "读取账目失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }
    }
}

// MARK: - 预览

#Preview("同比环比") {
    let today = DateOnly(key: 20251120)
    let current = Money(cents: 348_250)
    let yoy = PeriodComparison.make(current: current, baseline: Money(cents: 298_000))
    let mom = PeriodComparison.make(current: current, baseline: Money(cents: 312_000))
    let bounds = StatisticsCalculator.comparisonBounds(range: .thisMonth, today: today)

    return ScrollView {
        VStack(spacing: Theme.Spacing.md) {
            StatsCard(
                title: "支出同比环比",
                subtitle: "本月至今 · 与去年同月、上月同期比"
            ) {
                ComparisonCardContent(
                    comparison: StatisticsComparison(yoy: yoy, mom: mom),
                    bounds: bounds,
                    range: .thisMonth,
                    metric: .expense,
                    today: today
                )
            }

            StatsCard(title: "支出账户构成", subtitle: "2025 年 11 月") {
                AccountShareCardContent(
                    shares: [
                        AccountShare(
                            accountID: UUID(),
                            amount: Money(cents: 220_000),
                            ratio: 0.63,
                            isMerged: false
                        ),
                        AccountShare(
                            accountID: UUID(),
                            amount: Money(cents: 90_000),
                            ratio: 0.26,
                            isMerged: false
                        ),
                        AccountShare(
                            accountID: nil,
                            amount: Money(cents: 38_250),
                            ratio: 0.11,
                            isMerged: true
                        )
                    ],
                    metric: .expense,
                    title: { $0.isMerged ? "其他" : "招行储蓄卡" },
                    isArchived: { _ in false },
                    canDrill: { _ in true },
                    onSelect: { _ in }
                )
            }
        }
        .padding(.vertical, Theme.Spacing.md)
    }
    .background(Theme.Semantic.pageBackground)
}
