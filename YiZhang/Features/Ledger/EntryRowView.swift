//
//  EntryRowView.swift
//  一账 / Features / Ledger
//
//  职责：首页列表的一行（PRD 3.3）——左图标 / 中间两行（分类+备注、账户+来源徽章）/ 右金额。
//
//  四条展示纪律：
//  ① **金额颜色只表类型**：支出=主文本色、收入=绿、转账=灰。红留给"逾期/删除"，
//     否则一屏红字会让用户以为每笔账都出了问题；
//  ② **来源徽章只给非手动账目**（订阅 / 待办）：每一行都挂一个「手动」徽章等于没有徽章；
//  ③ **备注为空不占位**：分类名单独一行比"分类名 + 一片空白"更好看，
//     也不能用 `Spacer` 硬撑，那会让行高不一致；
//  ④ 转账用「转出 → 转入」表达，不用"分类"——转账没有分类（PRD 3.2.1）。
//
//  `isHighlighted` 只为"刚记完一笔"服务：首页在插入后 0.2s 内给该行一层浅色底，
//  让用户的眼睛能接住"新行插到哪儿了"（列表在顶部插入时，视线还停在按钮上）。
//

import SwiftUI

/// 账目行。
struct EntryRowView: View {

    let row: EntryRowModel

    /// 是否高亮（刚插入的那一笔）。
    var isHighlighted: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // AX 字号下「分类 + 备注 + 金额」挤在一行会把分类压成「…」（T24 截图实测）：
                // 改成「图标 + 文字」一行、金额单独一行，并且允许文字换行。
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        CategoryGlyph(iconName: row.iconName, colorHex: row.colorHex, size: .medium)

                        VStack(alignment: .leading, spacing: 2) {
                            accessibilityTitleBlock
                            subtitleLine
                        }
                    }

                    amountView
                        .padding(.leading, CategoryGlyph.Size.medium.side + Theme.Spacing.sm)
                }
            } else {
                HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                    CategoryGlyph(iconName: row.iconName, colorHex: row.colorHex, size: .medium)

                    VStack(alignment: .leading, spacing: 2) {
                        titleLine
                        subtitleLine
                    }

                    Spacer(minLength: Theme.Spacing.xs)

                    amountView
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
                // 高亮底色只在插入瞬间出现，用动画淡出（0.2s 由首页控制总时长）
                .animation(.easeOut(duration: 0.2), value: isHighlighted)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityIdentifier("ledger.row.\(row.id.uuidString)")
    }

    // MARK: - 子视图

    /// 第一行：分类名 + 备注（备注为空则不渲染，不留空白）。
    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(row.categoryName)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if !row.note.isEmpty {
                Text(row.note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
    }

    /// AX 字号下的标题块：分类独占一行、备注另起一行（都用 2 行上限，不省略成「…」）。
    private var accessibilityTitleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.categoryName)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if !row.note.isEmpty {
                Text(row.note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 第二行：账户（转账带箭头）+ 来源徽章。
    private var subtitleLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(accountText)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if row.source.needsBadge {
                sourceBadge
            }

            Spacer(minLength: 0)
        }
    }

    private var amountView: some View {
        HStack(spacing: 2) {
            if row.type.isTransfer {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Semantic.transfer)
                    .accessibilityHidden(true)
            }

            MoneyText(
                amount: row.amount,
                tone: row.tone,
                emphasis: .small,
                showsSign: row.type.isIncome
            )
            .lineLimit(1)
        }
    }

    private var sourceBadge: some View {
        Text(row.source.displayName)
            .font(Theme.Typography.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.Spacing.xxs)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule(style: .continuous))
    }

    // MARK: - 文本

    /// 「微信」/「支付宝 → 储蓄卡」
    private var accountText: String {
        if row.type.isTransfer, let to = row.toAccountName {
            return "\(row.accountName) → \(to)"
        }
        return row.accountName
    }

    private var accessibilityText: String {
        var parts: [String] = [row.categoryName]
        if !row.note.isEmpty { parts.append(row.note) }
        parts.append(accountText)
        parts.append(row.type.isIncome ? "收入\(row.amount.accessibilityText)" : row.amount.accessibilityText)
        if row.source.needsBadge { parts.append("来自\(row.source.displayName)") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 预览

#Preview("账目行") {
    let today = DateOnly(year: 2026, month: 11, day: 21) ?? .zero
    VStack(spacing: 0) {
        EntryRowView(
            row: EntryRowModel(
                amount: Money(cents: 2800),
                note: "午饭",
                day: today
            )
        )
        EntryRowView(
            row: EntryRowModel(
                type: .income,
                amount: Money(cents: 1_200_000),
                note: "11 月工资",
                categoryName: "工资",
                iconName: "banknote",
                colorHex: "#2E7D32",
                accountName: "储蓄卡",
                day: today
            )
        )
        EntryRowView(
            row: EntryRowModel(
                type: .transfer,
                amount: Money(cents: 50000),
                note: "",
                categoryName: "转账",
                iconName: "arrow.left.arrow.right",
                colorHex: "#5F6368",
                accountName: "支付宝",
                toAccountName: "储蓄卡",
                day: today
            )
        )
        EntryRowView(
            row: EntryRowModel(
                amount: Money(cents: 2500),
                note: "订阅：视频会员",
                categoryName: "订阅服务",
                iconName: "arrow.triangle.2.circlepath",
                colorHex: "#00838F",
                accountName: "微信",
                source: .subscription,
                day: today
            ),
            isHighlighted: true
        )
    }
    .padding(.vertical, Theme.Spacing.xs)
    .background(Theme.Semantic.cardBackground)
    .padding()
    .background(Theme.Semantic.pageBackground)
}
