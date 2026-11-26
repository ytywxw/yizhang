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
    ///
    /// 语义随行状态变化（见 `menu(onDelete:)`）：
    /// - 已完成 → 「删除这条记录」（只删记录，不动重复设置）；
    /// - 未完成 + 非重复 → 「删除」；
    /// - 未完成 + 重复 → 不出这一项，改出下面两个。
    var onDelete: (() -> Void)?

    /// 「⋯」→ 删除这一期（未完成 + 重复才有；系列继续）。
    var onDeleteCurrentOccurrence: (() -> Void)?

    /// 「⋯」→ 删除此次及以后（未完成 + 重复才有；系列到此为止）。
    var onDeleteAndStopSeries: (() -> Void)?

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
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: - 组成

    /// 行内标识符的公共后缀：`<标题>.<未完成 open / 已完成 done>`。
    ///
    /// 为什么必须带状态：重复待办完成时 `TodoService.complete` 会 spawn 下一期，
    /// 而新一期的**标题和刚完成那条完全相同**（一份已完成、一份未完成）。只用标题做后缀时
    /// 两行会撞成同一个标识符，UI 测试只能退回 `element(boundBy:)` 按行序取——
    /// 种子顺序一改就全错，第二个维护的人会直接把测试删掉。
    ///
    /// 标识符是给测试用的，不是给用户看的：这里用标题而不是 UUID，
    /// 是因为测试必须能在不知道 id 的前提下写出 `todo.row.menu.续费会员.done` 这种可读的定位。
    private var axSuffix: String {
        "\(row.title).\(row.isDone ? "done" : "open")"
    }

    private var accessibilityID: String { "todo.row.\(axSuffix)" }

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
        .accessibilityIdentifier("todo.row.checkbox.\(axSuffix)")
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

    /// 「⋯」菜单：三分支（V1.1 / F-TODO-11）。
    ///
    /// | 行状态 | 菜单项 |
    /// | --- | --- |
    /// | 未完成 + 重复 | 移到明天 / 删除这一期 / 删除此次及以后 |
    /// | 未完成 + 不重复 | 移到明天 / 删除 |
    /// | 已完成 | 删除这条记录（**只有这一项**，且不碰重复设置） |
    ///
    /// 为什么已完成的重复待办**不能**出「删除此次及以后」：那条历史记录是"我已经做过了"
    /// 的证据，删它不该产生"以后也不做了"的副作用。两个语义放同一个按钮里，
    /// 用户点完才发现系列被终止了 —— 这是删数据里最难挽回的一种误操作。
    private func menu(onDelete: @escaping () -> Void) -> some View {
        Menu {
            if row.isDone {
                Button(role: .destructive, action: onDelete) {
                    Label("删除这条记录", systemImage: "trash")
                }
            } else {
                if let onPostpone {
                    Button(action: onPostpone) {
                        Label("移到明天", systemImage: "calendar.badge.clock")
                    }
                }

                if row.isRepeating {
                    if let onDeleteCurrentOccurrence {
                        Button(role: .destructive, action: onDeleteCurrentOccurrence) {
                            Label("删除这一期", systemImage: "calendar.badge.minus")
                        }
                    }
                    if let onDeleteAndStopSeries {
                        Button(role: .destructive, action: onDeleteAndStopSeries) {
                            Label("删除此次及以后", systemImage: "trash.slash")
                        }
                    }
                } else {
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: Theme.minimumTapSize, height: Theme.minimumTapSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("更多操作"))
        .accessibilityIdentifier("todo.row.menu.\(axSuffix)")
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
