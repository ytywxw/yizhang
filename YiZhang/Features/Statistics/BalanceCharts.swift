//
//  BalanceCharts.swift
//  一账 / Features / Statistics
//
//  职责：三张图（T19 P0）——近 6 个月收支对比 / 分类占比环形 / 本月累计趋势。
//
//  ## 每个图都必须有等价的文本描述
//
//  图表的 `.accessibilityLabel` 不能是「图表」两个字——VoiceOver 用户听到的就该是
//  视力正常的人看到的那句结论（"近 6 个月支出从 ¥2,960 增长到 ¥4,180"）。
//  所以每张图都把 ViewModel 里算好的 summary 传进来当 label，图本身 `.accessibilityHidden`。
//
//  ## 空态一律不画坐标系
//
//  空坐标系传达的是"有数据但都是 0"，而真实情况是"没有数据"。两者要区分开，
//  所以三张图各自在数据为空时**整体换成一句话**（见 `StatisticsEmptyStates`）。
//

import Charts
import SwiftUI

// MARK: - AX 字号兜底

/// 无障碍字号下的图表替身：**一句结论 + 可读的数字**，而不是一张字叠字的图。
///
/// 为什么不是"把图缩小"：AX 字号下坐标轴标签会互相压住（`60000` 和 `40000` 叠在一起），
/// 这不是"不好看"，是"读不出数"。Apple 对这类情况的做法就是把图替换成文字摘要——
/// 视力正常的人看到的本来就是那一句结论（`summary` 与图表的 `.accessibilityLabel` 同源）。
struct ChartAccessibilityFallback: View {

    let summary: String
    /// 卡片里的补充说明（比如"点某个月可以跳到那个月的账本"）。
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(summary)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let hint {
                Text(hint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

// MARK: - 图 1：近 6 个月收支对比

/// 近 6 个月支出 / 收入双柱。
struct MonthlyFlowChart: View {

    let series: [MonthlyFlow]
    /// 可访问性结论（由 ViewModel 生成）。
    let summary: String
    /// 点某一根柱子 → 切到该月账本。
    var onSelectMonth: (Int32) -> Void

    var body: some View {
        Chart {
            ForEach(series) { flow in
                BarMark(
                    x: .value("月份", flow.label),
                    y: .value("金额", flow.expense.doubleAmount)
                )
                .foregroundStyle(by: .value("类型", "支出"))
                .position(by: .value("类型", "支出"))
                .cornerRadius(3)

                BarMark(
                    x: .value("月份", flow.label),
                    y: .value("金额", flow.income.doubleAmount)
                )
                .foregroundStyle(by: .value("类型", "收入"))
                .position(by: .value("类型", "收入"))
                .cornerRadius(3)
            }
        }
        .chartForegroundStyleScale([
            "支出": Color.primary,
            "收入": Theme.Semantic.income
        ])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(ChartAxisText.yuan(amount))
                            .font(Theme.Typography.caption)
                    }
                }
            }
        }
        .frame(height: 200)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        // 点在哪根柱子上就切到哪个月：用 x 轴位置反查
                        guard let plotFrame = proxy.plotFrame else { return }
                        let originX = geometry[plotFrame].origin.x
                        let relativeX = location.x - originX
                        guard let label: String = proxy.value(atX: relativeX),
                              let flow = series.first(where: { $0.label == label }) else { return }
                        onSelectMonth(flow.monthKey)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary))
        .accessibilityIdentifier("stats.chart.monthly")
    }
}

// MARK: - 图 2：分类占比环形

/// 分类占比环形图（中心显示支出合计）。
struct CategoryShareChart: View {

    let shares: [CategoryShare]
    let total: Money
    /// 环中心的小标题（「支出合计」/「收入合计」）。
    let totalTitle: String
    /// 标题解析（「餐饮」/「其他」/「未分类」）。
    let title: (CategoryShare) -> String
    /// 颜色十六进制。
    let colorHex: (CategoryShare) -> String
    let summary: String
    /// 点扇区 → 下钻。
    var onSelect: (CategoryShare) -> Void

    /// `chartAngleSelection` 的临时选择值（金额域）。
    @State private var selectedAngle: Double?

    var body: some View {
        Chart(shares) { share in
            SectorMark(
                angle: .value("金额", share.amount.doubleAmount),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(Theme.categoryColor(hex: colorHex(share)))
        }
        .chartLegend(.hidden)
        .frame(height: 200)
        .chartBackground { _ in
            VStack(spacing: Theme.Spacing.xxs) {
                Text(totalTitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Text(total.formatted())
                    .font(Theme.Typography.amountMedium)
                    .foregroundStyle(.primary)
                    // 内圈直径只有 ~110pt：五位数以上的金额必须缩，否则会被圆环切断
                    // （实测「¥12000.00」两侧都被切掉了）
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: 110)
            }
        }
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, newValue in
            guard let newValue, let share = share(containing: newValue) else { return }
            // 选完立刻复位：这个值只是"手指落在哪个扇区"的临时产物，
            // 留着会让下一次点击因为值没变而不触发 onChange
            selectedAngle = nil
            onSelect(share)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary))
        .accessibilityIdentifier("stats.chart.category")
    }

    /// 把 `chartAngleSelection` 给出的金额落进对应的扇区。
    ///
    /// 因为 `SectorMark` 的 angle 绑的就是金额，系统给回的选择值也在金额域上，
    /// 所以只要按金额累计区间找即可——不需要自己换算角度（那样一改排序就会错位）。
    private func share(containing amount: Double) -> CategoryShare? {
        var cursor = 0.0
        for share in shares {
            cursor += share.amount.doubleAmount
            if amount <= cursor { return share }
        }
        return shares.last
    }
}

// MARK: - 图 3：本月累计支出趋势

/// 本月累计支出折线（实线）+ 上月同期（虚线）。
struct CumulativeTrendChart: View {

    let points: [DailyTrendPoint]
    /// 今天（用来只画到今天为止的实线，未来部分不画）。
    let today: DateOnly
    let summary: String
    /// 选中的日（用于 tooltip）。
    @Binding var selectedDay: Int?

    var body: some View {
        Chart {
            // 上月同期：虚线
            ForEach(points) { point in
                if let previous = point.previousCumulative {
                    LineMark(
                        x: .value("日", point.day),
                        y: .value("上月累计", previous.doubleAmount),
                        series: .value("系列", "上月")
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }
            }

            // 本月：实线（只画到今天的累计，未来部分不画）
            ForEach(points) { point in
                if point.day <= today.day {
                    LineMark(
                        x: .value("日", point.day),
                        y: .value("本月累计", point.cumulative.doubleAmount),
                        series: .value("系列", "本月")
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                    .symbol(.circle)
                    .symbolSize(10)
                }
            }

            if let selectedDay, let point = points.first(where: { $0.day == selectedDay }) {
                RuleMark(x: .value("选中", point.day))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("日", point.day),
                    y: .value("本月累计", point.cumulative.doubleAmount)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(90)
                .annotation(position: .top, spacing: Theme.Spacing.xxs) {
                    tooltip(point)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDays) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                AxisValueLabel {
                    if let day = value.as(Int.self) {
                        Text("\(day)日")
                            .font(Theme.Typography.caption)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(ChartAxisText.yuan(amount))
                            .font(Theme.Typography.caption)
                    }
                }
            }
        }
        .frame(height: 200)
        .chartXSelection(value: Binding(
            get: { selectedDay },
            set: { selectedDay = $0 }
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary))
        .accessibilityIdentifier("stats.chart.trend")
    }

    /// X 轴要标的日。
    ///
    /// 固定的 1/8/15/22 里，凡是与"今天"挨得太近（≤3 天）的一律让位给今天——
    /// 否则 21 日和 22 日两个标签会挤在一起，实测出来是「2122日」这种糊字。
    private var axisDays: [Int] {
        let fixed = [1, 8, 15, 22]
        var days = fixed.filter { abs($0 - today.day) > 3 }
        days.append(today.day)
        return Array(Set(days)).sorted()
    }

    private func tooltip(_ point: DailyTrendPoint) -> some View {
        VStack(spacing: 2) {
            Text("\(point.day) 日")
                .font(Theme.Typography.captionStrong)
            Text("累计 \(point.cumulative.formatted())")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            if let previous = point.previousCumulative {
                Text("上月 \(previous.formatted())")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
                .shadow(color: Theme.Shadow.cardColor, radius: 6, y: 2)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - 轴刻度文案

/// Y 轴刻度：`doubleAmount` 的域是「元」，`MoneyText` 的入参是「分」，这里换回去。
///
/// 少乘这一百，轴标签就会小两个数量级（¥12,000 显示成 120），
/// 而这意味着用户读到的是错的数——比图难看严重得多。
private enum ChartAxisText {

    static func yuan(_ amount: Double) -> String {
        MoneyText.wholeYuanText(Money(cents: Int64((amount * 100).rounded())), showsSymbol: false)
    }
}

// MARK: - Money → Double

extension Money {
    /// 图表要 `Double`；只在绘图边界转换，业务计算一律 `Int64` 分（A1 铁律）。
    var doubleAmount: Double { Double(cents) / 100.0 }
}
