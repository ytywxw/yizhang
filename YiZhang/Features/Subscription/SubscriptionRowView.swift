//
//  SubscriptionRowView.swift
//  一账 / Features / Subscription
//
//  职责：订阅列表的一行（PRD 4.5）——图标 + 名称 + 「¥25 / 月」+ 下次扣费「11月25日（5天后）」+ chevron。
//
//  三处细节是刻意的：
//  ① **试用 / 待续费 / 周期异常** 三个标签用不同颜色：前两个是状态提示（信息），
//     第三个是数据异常（危险色）。混成一色会让「异常」看起来像正常状态。
//  ② 金额与日期用等宽数字：列表滚动时数字宽度变化会让整列左右抖动（`Money` 已保证分 → 元只有一处）。
//  ③ 整行可点但**不做成 `NavigationLink`**：详情页在 T13，现在点开的是编辑 Sheet 的壳；
//     用 `NavigationLink` 会先把页面推过去再发现没内容，回退路径也更别扭。
//

import SwiftUI

/// 订阅行。
struct SubscriptionRowView: View {

    let row: SubscriptionListViewModel.RowModel

    /// 点整行（打开编辑页；T13 接入后改成推详情）。
    var onTap: (() -> Void)?

    /// 「已续费」按钮回调（仅在 `isAwaitingRenewal` 为真时出现）。
    var onRenew: (() -> Void)?

    /// 「⋯」菜单：暂停 / 恢复（已取消的订阅不出现）。
    var onTogglePause: (() -> Void)?

    /// 「⋯」菜单：删除（会弹二次确认）。
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // 可点区域只包住"图标 + 文本"：把「已续费」按钮也包进来会让两者互相吃掉点击，
            // 无障碍上也会变成一个元素（按钮的动作就消失了）。
            HStack(spacing: Theme.Spacing.sm) {
                CategoryGlyph(iconName: row.iconName, colorHex: row.colorHex, size: .medium)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    titleLine
                    subtitleLine

                    if let trialText = row.trialText {
                        Text(trialText)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Spacing.xs)
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityText))
            .accessibilityAddTraits(onTap == nil ? AccessibilityTraits() : .isButton)

            if row.isAwaitingRenewal, let onRenew {
                Button("已续费", action: onRenew)
                    .font(Theme.Typography.captionStrong)
                    .buttonStyle(.borderless)
                    .frame(minHeight: Theme.minimumTapSize)
                    .accessibilityLabel(Text("把「\(row.name)」记为已续费"))
            }

            // 右侧从 chevron 换成「⋯」菜单：`ScrollView` 里没有 `.swipeActions`（T12 的决定），
            // 而"长按才出现"是隐藏交互——订阅管理页的用户不该靠猜。
            // 菜单与长按调用同一套闭包，两条入口都通向同一个二次确认。
            if onDelete != nil || onTogglePause != nil {
                Menu {
                    if row.status != .cancelled, let onTogglePause {
                        Button {
                            onTogglePause()
                        } label: {
                            Label(
                                row.status == .paused ? "恢复" : "暂停",
                                systemImage: row.status == .paused ? "play.fill" : "pause.fill"
                            )
                        }
                    }
                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("更多操作"))
                .accessibilityIdentifier("subscription.menu")
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    // MARK: - 子视图

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(row.name)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if row.isTrial {
                badge("试用", tint: Theme.Semantic.transfer)
            }
            if row.isAwaitingRenewal {
                badge("待续费", tint: Theme.Semantic.danger)
            }
            if row.isTruncated {
                badge("周期异常", tint: Theme.Semantic.danger)
            }
        }
    }

    private var subtitleLine: some View {
        Text("\(row.amountPerCycleText) · \(row.nextBillingText)")
            .font(Theme.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // 允许折成两行：「¥199.00 / 月 · 11月18日（已逾期 3 天）」在带「已续费」按钮的窄行里
            // 一行摆不下，截断成「…已逾期 3…」比折行更糟——数字被切掉就等于信息丢失。
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.xxs)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var accessibilityText: String {
        var parts: [String] = [row.name, row.amountPerCycleText, row.nextBillingText]
        if let trialText = row.trialText { parts.append(trialText) }
        if row.isAwaitingRenewal { parts.append("待续费") }
        if row.isTruncated { parts.append("周期异常") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 预览

#Preview("订阅行") {
    List {
        SubscriptionRowView(
            row: SubscriptionListViewModel.RowModel(
                id: UUID(),
                name: "视频会员",
                iconName: "tv",
                colorHex: "#B26A00",
                amountPerCycleText: "¥25.00 / 月",
                nextBillingText: "11月25日（5天后）",
                nextBillingDayKey: 20261125,
                status: .active,
                autoRenew: true,
                isTrial: false,
                trialText: nil,
                isAwaitingRenewal: false,
                isTruncated: false
            ),
            onTogglePause: {},
            onDelete: {}
        )
        SubscriptionRowView(
            row: SubscriptionListViewModel.RowModel(
                id: UUID(),
                name: "健身房月卡",
                iconName: "dumbbell",
                colorHex: "#2E7D32",
                amountPerCycleText: "¥199.00 / 月",
                nextBillingText: "11月18日（已逾期 3 天）",
                nextBillingDayKey: 20261118,
                status: .active,
                autoRenew: false,
                isTrial: true,
                trialText: "试用中，5 天后开始扣费",
                isAwaitingRenewal: true,
                isTruncated: false
            ),
            onRenew: {},
            onTogglePause: {},
            onDelete: {}
        )
    }
    .listStyle(.plain)
}
