//
//  CommonViews.swift
//  一账 / Core / DesignSystem
//
//  职责：跨页面复用的基础组件——空态、分组头、Toast（含 3 秒撤销）、加载骨架。
//
//  为什么 Toast 放在设计系统而不是某个 Feature：R-EDIT-3 的「3 秒撤销」是全局交互约定，
//  记账删除、待办删除、订阅删除都要用同一套计时与文案位置。写在某一页里必然被复制三份，
//  然后三份的自动消失时间不一样（这是最容易在真机上被用户发现的不一致）。
//
//  Toast 的计时器**不落库**（架构 §5.3）：App 在 3 秒内被杀 → 撤销入口消失，但账目仍在。
//  这样避免了"未决撤销状态持久化"的整套复杂度。
//

import SwiftUI

// MARK: - 空态

/// 空状态：图标 + 标题 + 副文案 + 可选按钮。
///
/// 文案规范（PRD §1.3 / T24 验收）：一句话说清"这里本该有什么"，不要写"暂无数据"这种无信息量的句子。
struct EmptyStateView: View {
    let iconName: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // 空态图标是"界面图标"，不走分类的 40 图标白名单
            // （白名单只用于用户可改的分类图标；界面图标由代码写死，`list.bullet.rectangle` 等合法符号
            //   并不在白名单里，误用 sanitize 会全部退化成省略号）
            Image(systemName: iconName.isEmpty ? "tray" : iconName)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.Typography.headline)
                        .frame(minHeight: Theme.minimumTapSize)
                        .padding(.horizontal, Theme.Spacing.md)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Theme.Spacing.xxs)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 分组头

/// 列表分组头：左侧标题，右侧可选说明（数量 / 合计）。
struct SectionHeaderView: View {
    let title: String
    var detail: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // AX 字号下标题和右侧合计挤在同一行会互相压字（T24 截图实测）：
        // 无障碍字号时改成上下两行，常规字号保持一行。
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))

        return layout {
            Text(title)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Theme.Spacing.xs)
            }
            if let detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toast

/// 一条 Toast。
///
/// `action` 是"撤销"这类一次性动作，因此 Toast 被替换或消失后不再可用（不做持久化）。
struct ToastItem: Identifiable {
    let id = UUID()
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// Toast 视图本体（不带计时，计时由 `.toast(item:)` 负责）。
struct ToastView: View {
    let item: ToastItem
    var onAction: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(item.message)
                .font(Theme.Typography.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)

            Spacer(minLength: 0)

            if let actionTitle = item.actionTitle {
                Button(actionTitle) {
                    onAction()
                }
                .font(Theme.Typography.headline)
                .foregroundStyle(.white)
                .frame(minWidth: Theme.minimumTapSize, minHeight: Theme.minimumTapSize)
                .accessibilityLabel(Text(actionTitle))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .padding(.horizontal, Theme.Spacing.md)
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .contain)
    }
}

/// Toast 宿主修饰符：3 秒后自动消失，取消或替换时重新计时。
private struct ToastModifier: ViewModifier {
    @Binding var item: ToastItem?
    /// 自动消失时长（R-EDIT-3：3 秒）
    var duration: Duration = .seconds(3)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let current = item {
                    ToastView(
                        item: current,
                        onAction: {
                            current.action?()
                            item = nil
                        },
                        onDismiss: { item = nil }
                    )
                    .padding(.bottom, Theme.Spacing.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: item?.id)
            .task(id: item?.id) {
                guard item != nil else { return }
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                item = nil
            }
    }
}

extension View {
    /// 挂一个 Toast。示例：
    /// ```swift
    /// @State private var toast: ToastItem?
    /// ...
    /// .toast(item: $toast)
    /// ```
    func toast(item: Binding<ToastItem?>, duration: Duration = .seconds(3)) -> some View {
        modifier(ToastModifier(item: item, duration: duration))
    }
}

// MARK: - 加载骨架

/// 列表加载骨架：与真实行同高的灰色块 + 呼吸动画。
///
/// 用途：切月/首帧时占位，避免"白屏 → 突然出现列表"的跳变（R-LIST-3）。
struct LoadingSkeleton: View {
    var rows: Int = 5
    var rowHeight: CGFloat = 56

    @State private var isDimmed = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<max(rows, 1), id: \.self) { _ in
                HStack(spacing: Theme.Spacing.sm) {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 12)
                            .frame(maxWidth: 160, alignment: .leading)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 10)
                            .frame(maxWidth: 96, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: rowHeight)
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
        .opacity(isDimmed ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: isDimmed)
        .onAppear { isDimmed = true }
        .accessibilityLabel(Text("正在加载"))
    }
}

// MARK: - 预览

#Preview("通用组件") {
    NavigationStack {
        ScrollView {
            EmptyStateView(
                iconName: "list.bullet.rectangle",
                title: "还没有一笔账",
                message: "点右下角的 + 记下第一笔，今天花了多少一目了然。",
                actionTitle: "记一笔",
                action: {}
            )

            SectionHeaderView(title: "11月20日 周四", detail: "合计 ¥128.00")

            LoadingSkeleton(rows: 3)
        }
    }
}
