//
//  TodoRowView.swift
//  一账 / Features / Todo
//
//  职责：待办列表的一行（T16）——左侧圆形勾选 + 标题 + 副行 + 「来自订阅」徽章 + 「⋯」菜单。
//
//  三处刻意的：
//  ① **勾选框是独立点击区**（44pt），不是整行的附属：整行点击要去详情，
//     把勾选也塞进整行会让"想看一眼详情"变成"手滑勾掉了"。
//  ② **逾期只染日期，不染标题**：标题全红会让整个列表看起来都在报警，
//     红色应该只标记"哪个日期出问题了"（这也是全项目"红只留给逾期和删除"的落地）。
//  ③ 已完成：标题加删除线 + 灰色 + 勾选实心，副行保留——用户核对"我勾的是不是这条"时
//     需要看到原来的日期与金额。
//

import SwiftUI

/// 待办行。
struct TodoRowView: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: TodoRowModel

    /// 点左侧圆圈（完成 / 已完成时由外部决定是否撤销）。
    var onToggle: () -> Void

    /// 点整行（进详情）。
    var onTap: () -> Void

    /// 「⋯」→ 移到明天（已完成的行不显示）。
    var onPostpone: (() -> Void)?

    /// 「⋯」→ 删除。
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
               spacing: Theme.Spacing.sm) {
            checkbox

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                titleLine
                if !row.subtitle.isEmpty {
                    subtitleLine
                }

                // AX 字号下「待办」徽章不再挤在右侧（会被压成两行），挪到文字下方
                if dynamicTypeSize.isAccessibilitySize, row.isFromSubscription {
                    subscriptionBadge
                }
            }

            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Theme.Spacing.xs)

                if row.isFromSubscription {
                    subscriptionBadge
                }
            }

            if let onDelete {
                menu(onDelete: onDelete)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("todo.row")
    }

    // MARK: - 组成

    private var checkbox: some View {
        Button(action: onToggle) {
            Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: row.isDone ? .semibold : .regular))
                .foregroundStyle(row.isDone ? Theme.Semantic.income : Color.secondary)
                .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(row.isDone ? "撤销完成「\(row.title)」" : "完成「\(row.title)」"))
        .accessibilityIdentifier("todo.row.checkbox")
    }

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if row.priority == .high && !row.isDone {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Semantic.danger)
                    .accessibilityHidden(true)
            }

            Text(row.title)
                .font(Theme.Typography.body)
                .foregroundStyle(row.isDone ? Color.secondary : Color.primary)
                .strikethrough(row.isDone, color: Color.secondary)
                // AX 字号一行只放得下 5-6 个字，2 行上限会把标题截成「…」（T24 截图实测）：
                // 无障碍字号放开到 4 行
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .multilineTextAlignment(.leading)
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if let dueText = row.dueText {
                // 逾期只染这段（见文件头 ②）
                Text(dueText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(row.isOverdue ? Theme.Semantic.danger : Color.secondary)
            }
            if row.dueText != nil, row.detailText != nil {
                Text("·")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            if let detailText = row.detailText {
                Text(detailText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel(Text(row.subtitle))
    }

    private var subscriptionBadge: some View {
        Text("来自订阅")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .accessibilityLabel(Text("这条待办来自订阅"))
    }

    private func menu(onDelete: @escaping () -> Void) -> some View {
        Menu {
            if !row.isDone, let onPostpone {
                Button(action: onPostpone) {
                    Label("移到明天", systemImage: "calendar.badge.clock")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("更多操作"))
        .accessibilityIdentifier("todo.row.menu")
    }
}

// MARK: - 预览

#Preview("待办行") {
    VStack(spacing: 0) {
        TodoRowView(
            row: TodoRowModel(
                id: UUID(),
                title: "买菜",
                dueText: "截止 11月22日",
                detailText: "买菜生鲜 ¥86.00",
                dueDay: 20261122,
                hasDueDate: true,
                isDone: false,
                isOverdue: false,
                hasExpense: true,
                priority: .none,
                isFromSubscription: false,
                hasLinkedEntry: false,
                linkedEntryDeleted: false
            ),
            onToggle: {},
            onTap: {},
            onPostpone: {},
            onDelete: {}
        )
        Divider()
        TodoRowView(
            row: TodoRowModel(
                id: UUID(),
                title: "交电费",
                dueText: "逾期 11月18日",
                detailText: nil,
                dueDay: 20261118,
                hasDueDate: true,
                isDone: false,
                isOverdue: true,
                hasExpense: false,
                priority: .high,
                isFromSubscription: true,
                hasLinkedEntry: false,
                linkedEntryDeleted: false
            ),
            onToggle: {},
            onTap: {},
            onPostpone: {},
            onDelete: {}
        )
        Divider()
        TodoRowView(
            row: TodoRowModel(
                id: UUID(),
                title: "取快递",
                dueText: "截止 11月21日",
                detailText: nil,
                dueDay: 20261121,
                hasDueDate: true,
                isDone: true,
                isOverdue: false,
                hasExpense: false,
                priority: .none,
                isFromSubscription: false,
                hasLinkedEntry: false,
                linkedEntryDeleted: false
            ),
            onToggle: {},
            onTap: {},
            onPostpone: nil,
            onDelete: {}
        )
    }
    .padding(.horizontal, Theme.Spacing.md)
    .background(Theme.Semantic.cardBackground)
}
