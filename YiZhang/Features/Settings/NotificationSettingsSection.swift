//
//  NotificationSettingsSection.swift
//  一账 / Features / Settings
//
//  职责：设置页的「通知」区块（T20）。
//
//  ## 三条刻意的设计
//
//  ① **被拒时给的是「前往系统设置」而不是"重新请求"**：iOS 的权限弹窗一辈子只弹一次，
//     被拒之后再 `requestAuthorization` 会立刻返回 denied 且不弹任何东西。
//     给用户一个"再点一次"的按钮等于骗他。
//  ② **明确写出"关掉通知不影响记账"**：这是产品硬要求，也是用户最怕的事
//     （"我不给通知权限，App 会不会不好用"）。文案要主动消除这个疑虑。
//  ③ **DEBUG 下可强制显示被拒态**：模拟器里没法真的拒权限，截图验收需要这个开关。
//

import SwiftUI
import UIKit

/// 设置页的通知区块。
struct NotificationSettingsSection: View {

    @Environment(AppEnvironment.self) private var environment

    /// 当前展示的权限状态（`.task` 里刷新）。
    @State private var permission: NotificationPermission = .notDetermined
    /// 已注册的通知条数（让用户知道"确实排上了"）。
    @State private var scheduledCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("通知")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                statusRow

                Divider().opacity(0.4).padding(.leading, Theme.Spacing.md)

                explanationRow

                if permission == .denied {
                    Divider().opacity(0.4).padding(.leading, Theme.Spacing.md)
                    openSettingsRow
                } else if permission == .notDetermined {
                    Divider().opacity(0.4).padding(.leading, Theme.Spacing.md)
                    requestRow
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Semantic.cardBackground)
            )
        }
        .padding(.horizontal, Theme.Spacing.md)
        .task { await refresh() }
        .onChange(of: environment.dataVersion) { _, _ in
            Task { await refresh() }
        }
        .accessibilityIdentifier("settings.notifications")
    }

    // MARK: - 行

    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(permission.canDeliver ? Theme.Semantic.income : .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(permission.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)

                Text(countText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(permission.displayName)。\(countText)"))
        .accessibilityIdentifier("settings.notifications.status")
    }

    private var explanationRow: some View {
        Text("订阅扣费、非自动续费到期、待办截止会在这里提醒。**关掉通知不影响记账和订阅自动入账**，只是收不到提醒。")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
    }

    private var openSettingsRow: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text("前往系统设置开启")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.minimumTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.notifications.openSettings")
    }

    private var requestRow: some View {
        Button {
            Task {
                _ = await environment.notifications.requestPermissionIfNeeded()
                await refresh(reschedule: true)
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text("开启提醒")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.minimumTapSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.notifications.request")
    }

    // MARK: - 数据

    private var iconName: String {
        switch permission {
        case .authorized, .provisional: return "bell.badge.fill"
        case .denied: return "bell.slash.fill"
        case .notDetermined: return "bell"
        }
    }

    private var countText: String {
        guard permission.canDeliver else {
            return "记账与自动入账不受影响"
        }
        return scheduledCount > 0 ? "已安排 \(scheduledCount) 条提醒（未来 30 天）" : "未来 30 天没有需要提醒的事"
    }

    private func refresh(reschedule: Bool = false) async {
        if reschedule {
            _ = await environment.rescheduleNotifications()
        }
        permission = await environment.notifications.refreshPermission()
        scheduledCount = await environment.notifications.pendingIdentifiers().count
    }
}

// MARK: - 预览

#Preview("通知区块") {
    NotificationSettingsPreview()
}

private struct NotificationSettingsPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            ScrollView {
                NotificationSettingsSection()
            }
            .background(Theme.Semantic.pageBackground)
            .environment(environment)
        } else {
            Text("预览数据不可用")
        }
    }
}
