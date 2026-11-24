//
//  CategoryGridView.swift
//  一账 / Features / Entry
//
//  职责：记账页的分类选择宫格（R-IN-2）——首屏只给「最近用过的 6 个」+「全部」，点「全部」展开。
//
//  为什么首屏不直接铺 19 个格子：
//  记账是"3 秒内完成"的动作，而真实使用中 80% 的记账落在 5-6 个分类里。
//  铺满 19 个格子会让每个格子变小、眼睛要多扫三行；先给最近 6 个 + 一个「全部」出口，
//  是最省事的选择：常走的路径一步到，冷门分类两步到。
//
//  两处硬约束：
//  ① **支出/收入分类互斥**：本组件只接收"当前类型"的分类，切换类型由 VM 负责，
//     组件不做过滤判断（免得两个地方各判断一次、判断结果不一致）；
//  ② 选中态必须**同时**有颜色与形状差异（`.isSelected` 无障碍 trait + 描边 + 底色），
//     只靠颜色会让色觉障碍用户在深色模式下看不出选了哪个。
//

import SwiftUI

/// 分类宫格。
struct CategoryGridView: View {

    /// 当前类型下的全部分类（由 VM 过滤好）。
    let categories: [CategoryOption]

    /// 最近用过的分类（按最近优先）。
    let recentCategories: [CategoryOption]

    /// 已选分类 id。
    let selectedCategoryID: UUID?

    /// 选择回调。
    var onSelect: (UUID) -> Void

    /// 是否展开成全部。
    @State private var isExpanded = false

    /// 4 列等宽（19 个分类刚好 5 行）。
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.sm),
        count: 4
    )

    /// 收起状态显示的项：最近用过的（不足 4 个时用全部的前几个补齐，避免一行只有 1 个格子）。
    private var collapsedItems: [CategoryOption] {
        guard !recentCategories.isEmpty else {
            return Array(categories.prefix(7))
        }
        return recentCategories
    }

    /// 展开状态显示的项：全部。
    private var expandedItems: [CategoryOption] { categories }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header

            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(isExpanded ? expandedItems : collapsedItems) { category in
                    cell(for: category)
                }

                // 第 8 个位置的落点：收起时是「全部」，展开时是「收起」。
                // 固定成第 8 格而不是追加在末尾：收起时最近分类常常只有 3-4 个，
                // 追加在末尾会让「全部」跑到第二行第一格，位置每次记完账都在跳。
                toggleCell
            }
        }
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .accessibilityIdentifier("entry.categoryGrid")
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(isExpanded ? "全部分类" : "最近使用")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if categories.isEmpty {
                Text("没有可用分类")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func cell(for category: CategoryOption) -> some View {
        let isSelected = category.id == selectedCategoryID
        return Button {
            onSelect(category.id)
        } label: {
            VStack(spacing: Theme.Spacing.xxs) {
                CategoryGlyph(iconName: category.iconName, colorHex: category.colorHex, size: .medium)

                Text(category.name)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isSelected ? Theme.categoryTint(hex: category.colorHex) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.categoryColor(hex: category.colorHex) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.minimumTapSize)
        .accessibilityLabel(Text(category.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("entry.category.\(category.name)")
    }

    /// 展开/收起按钮（占一个格子，视觉与分类格子对齐）。
    private var toggleCell: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: isExpanded ? "chevron.up" : "square.grid.2x2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: CategoryGlyph.Size.medium.side, height: CategoryGlyph.Size.medium.side)
                    .background(Color.secondary.opacity(0.1), in: Circle())

                Text(isExpanded ? "收起" : "全部")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.minimumTapSize)
        .accessibilityLabel(Text(isExpanded ? "收起分类" : "展开全部分类"))
        .accessibilityIdentifier("entry.category.toggle")
    }
}

// MARK: - 预览

#Preview("分类宫格") {
    CategoryGridPreview()
}

private struct CategoryGridPreview: View {

    private var categories: [CategoryOption] {
        [
            ("餐饮", "fork.knife", "#C0392B"),
            ("买菜生鲜", "cart", "#2E7D32"),
            ("交通出行", "tram", "#1565C0"),
            ("购物", "bag", "#8A5CD1"),
            ("居住", "house", "#B26A00"),
            ("通讯网络", "wifi", "#00838F"),
            ("娱乐", "gamecontroller", "#AD1457")
        ].map { item in
            CategoryOption(
                id: UUID(),
                name: item.0,
                iconName: item.1,
                colorHex: item.2,
                type: .expense
            )
        }
    }

    var body: some View {
        CategoryGridView(
            categories: categories,
            recentCategories: Array(categories.prefix(4)),
            selectedCategoryID: categories.first?.id,
            onSelect: { _ in }
        )
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Semantic.pageBackground)
    }
}
