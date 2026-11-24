//
//  AccountPickerRow.swift
//  一账 / Features / Entry
//
//  职责：记账页的账户选择（R-ACC-1 / F-ACC-07）——横向 chip 单选；转账模式下是「从 → 到」双选。
//
//  为什么用横向 chips 而不是 `Picker` 或 `Menu`：
//  ① 账户只有 5 个，横向 chips 一屏放得下，一眼能看到"现在记在哪个账户"；
//  ② `Picker(.menu)` 把当前值藏在菜单里，记账这种高频动作不该多点一次；
//  ③ chips 的点击区天然 ≥44pt，且每个 chip 是独立无障碍元素（VoiceOver 可以直接左右滑选）。
//
//  转账双选的一条硬约束：**转出账户不能出现在转入列表里**。
//  这不是过滤显示就够了——数据层也会校验（`LedgerService`），
//  这里过滤是为了让用户根本点不到那个非法组合，而不是让他点了再报错。
//

import SwiftUI

// MARK: - 单选

/// 账户选择行（横向 chip）。
struct AccountPickerRow: View {

    /// 左侧标签（「账户」/「从」/「到」）。
    var title: String = "账户"

    let accounts: [AccountOption]

    let selectedID: UUID?

    var onSelect: (UUID) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(accounts) { account in
                        chip(for: account)
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .accessibilityIdentifier("entry.account.\(title)")
    }

    private func chip(for account: AccountOption) -> some View {
        let isSelected = account.id == selectedID
        return Button {
            onSelect(account.id)
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: account.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)

                Text(account.name)
                    .font(Theme.Typography.captionStrong)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Color.accentColor : Theme.Semantic.cardBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.secondary.opacity(isSelected ? 0 : 0.18), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // 32pt 的胶囊外面再撑到 44pt 触控高度（HIG），但不改变视觉尺寸
        .frame(minHeight: Theme.minimumTapSize)
        .accessibilityLabel(Text(account.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("entry.account.\(account.name)")
    }
}

// MARK: - 转账双选

/// 转账模式下的「从 → 到」双选。
struct TransferAccountPicker: View {

    let accounts: [AccountOption]

    let sourceID: UUID?

    let targetID: UUID?

    var onSelectSource: (UUID) -> Void

    var onSelectTarget: (UUID) -> Void

    /// 转入可选集合：排除转出账户（点不到非法组合）。
    private var targetAccounts: [AccountOption] {
        accounts.filter { $0.id != sourceID }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            AccountPickerRow(
                title: "从",
                accounts: accounts,
                selectedID: sourceID,
                onSelect: onSelectSource
            )

            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .leading)
                    .accessibilityHidden(true)

                Text("转出账户与转入账户不能相同")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)

            AccountPickerRow(
                title: "到",
                accounts: targetAccounts,
                selectedID: targetID,
                onSelect: onSelectTarget
            )
        }
        .accessibilityIdentifier("entry.transferPicker")
    }
}

// MARK: - 预览

#Preview("账户选择") {
    let accounts = [
        AccountOption(id: UUID(), name: "现金", symbolName: AccountKind.cash.symbolName),
        AccountOption(id: UUID(), name: "微信", symbolName: AccountKind.wechat.symbolName),
        AccountOption(id: UUID(), name: "支付宝", symbolName: AccountKind.alipay.symbolName),
        AccountOption(id: UUID(), name: "储蓄卡", symbolName: AccountKind.debit.symbolName)
    ]
    VStack(spacing: Theme.Spacing.md) {
        AccountPickerRow(accounts: accounts, selectedID: accounts[1].id, onSelect: { _ in })
        TransferAccountPicker(
            accounts: accounts,
            sourceID: accounts[0].id,
            targetID: accounts[2].id,
            onSelectSource: { _ in },
            onSelectTarget: { _ in }
        )
    }
    .padding(.vertical, Theme.Spacing.md)
    .background(Theme.Semantic.pageBackground)
}
