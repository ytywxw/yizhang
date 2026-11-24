//
//  CategoryGlyph.swift
//  一账 / Core / DesignSystem
//
//  职责：分类图标胶囊（圆底 + 分类色 + SF Symbol）的唯一实现。
//
//  三档尺寸对应三处使用场景：
//  - small（28pt）：列表行内、筛选 chip
//  - medium（40pt）：分类宫格
//  - large（56pt）：分类管理页、详情页头部
//
//  深色适配由 `Theme.categoryColor(hex:)` 负责（同一 hex 在深色模式下自动提亮），
//  因此本组件不写任何 `if colorScheme == .dark` 分支——换色只改一处。
//

import SwiftUI

/// 分类 / 账户图标胶囊。
struct CategoryGlyph: View {

    /// 尺寸档位。
    enum Size: Hashable, Sendable {
        case small
        case medium
        case large

        var side: CGFloat {
            switch self {
            case .small: return 28
            case .medium: return 40
            case .large: return 56
            }
        }

        var iconFont: Font {
            switch self {
            case .small: return .system(size: 13, weight: .semibold)
            case .medium: return .system(size: 17, weight: .semibold)
            case .large: return .system(size: 24, weight: .semibold)
            }
        }
    }

    let iconName: String
    let colorHex: String
    var size: Size = .medium

    var body: some View {
        Image(systemName: resolvedIconName)
            .font(size.iconFont)
            .foregroundStyle(Theme.categoryColor(hex: colorHex))
            .frame(width: size.side, height: size.side)
            .background(Theme.categoryTint(hex: colorHex), in: Circle())
            // 图标是纯装饰：分类名在主文本里已经念出来了，重复朗读只会更吵
            .accessibilityHidden(true)
    }

    /// 只接受白名单内的符号，避免未知名字渲染成空白方块。
    private var resolvedIconName: String {
        PresetCatalog.sanitizedSymbolName(iconName)
    }
}

// MARK: - 预览

#Preview("分类图标") {
    HStack(spacing: Theme.Spacing.md) {
        CategoryGlyph(iconName: "fork.knife", colorHex: "#C0392B", size: .small)
        CategoryGlyph(iconName: "cart", colorHex: "#2E7D32", size: .medium)
        CategoryGlyph(iconName: "airplane", colorHex: "#1565C0", size: .large)
        CategoryGlyph(iconName: "不存在的符号", colorHex: "#8A5CD1", size: .medium)
    }
    .padding()
}
