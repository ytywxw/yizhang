//
//  TrashView.swift
//  一账 / Features / Settings
//
//  职责：「最近删除」页（V1.1 / PRD §6.1）——按删除日分组的列表 + 行详情 + 恢复 + 彻底删除。
//
//  ## 本页只做三件事，其余都交给下层
//
//  - 渲染 `TrashViewModel` 已经算好的分组（**排序与日期标题都不在这里做**：
//    排序在 `TrashService`、标题在 `TrashViewModel`，本页一个 `sorted` 都没有）；
//  - 把用户动作翻译成 VM 调用，成败都走 Toast（本页不弹错误弹窗：
//    "找回一条被删的账"这种时刻弹窗只会让人更慌，Toast 说明结果就够了）；
//  - 详情页以**只读**形式打开（`EntryDetailView(isReadOnly: true)`），
//    只读态的底部按钮换成「恢复」/「彻底删除」——正在回收站里的账不该还能编辑。
//
//  ## 为什么行尾是「剩余 N 天」而不是「删除于 X」
//
//  分组标题已经写了删除日（今天/昨天/11月18日），行里再说一遍是重复；
//  而"还能救几天"是用户在这一页唯一真正关心的时间信息。
//  1 天内过期的用 `danger` 色——这是全项目唯一允许把红色用在金额以外的地方之一。
//

import SwiftUI

/// 最近删除页。
struct TrashView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = TrashViewModel()
    @State private var toast: ToastItem?
    /// 点开的那一行（只读详情）。
    @State private var detailEntryID: UUID?
    /// 「全部彻底删除」的二次确认。
    @State private var showsPurgeAllConfirmation = false

    var body: some View {
        content
            .background(Theme.Semantic.pageBackground)
            .navigationTitle("最近删除")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.count > 0 {
                    bottomBar
                }
            }
            // 一个钩子覆盖两件事：首次进页加载 + 任何写入提交后重读。
            //
            // `attach` 是幂等的（设依赖 + 重读），所以这里不需要再写一个 `.task { }`——
            // 两个 task 会在首帧各读一次，白白多一轮 fetch。
            .task(id: environment.dataVersion) {
                viewModel.attach(environment)
            }
            .navigationDestination(item: $detailEntryID) { id in
                // 只读详情：正在回收站里的账不该还能编辑。
                // 结果 Toast 由本页展示——详情页恢复成功后会立刻 dismiss，
                // 一个随视图消失的 Toast 等于没提示。
                EntryDetailView(entryID: id, isReadOnly: true) { message in
                    toast = ToastItem(message: message)
                }
            }
            .confirmationDialog(
                "彻底删除全部 \(viewModel.count) 条账目？",
                isPresented: $showsPurgeAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("彻底删除 \(viewModel.count) 条", role: .destructive) {
                    purgeAll()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("彻底删除后无法恢复，这些账目会从数据库里移除。")
            }
            .toast(item: $toast)
            .accessibilityIdentifier("trash.root")
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if !viewModel.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                }
            }

            ForEach(viewModel.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        Button {
                            detailEntryID = row.id
                        } label: {
                            rowContent(row)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(row.accessibilityText))
                        .accessibilityIdentifier("trash.row")
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
    }

    private func groupHeader(_ group: TrashViewModel.Group) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(group.title)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Text("\(group.count) 条")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .textCase(nil) // 中文标题不需要系统的大小写转换
    }

    /// 一行：分类图标 + 分类名 + 备注 ｜ 金额 ｜ 原日期 + 来源徽章 + 剩余天数。
    private func rowContent(_ row: TrashViewModel.Row) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            CategoryGlyph(iconName: row.iconName, colorHex: row.colorHex, size: .medium)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(row.categoryName)
                        .font(Theme.Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: Theme.Spacing.xs)

                    MoneyText(
                        amount: row.amount,
                        tone: MoneyText.Tone(type: row.type),
                        emphasis: .small,
                        showsSign: row.type.isIncome
                    )
                    .lineLimit(1)
                }

                if !row.note.isEmpty {
                    Text(row.note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: Theme.Spacing.xxs) {
                    Text("原日期 \(row.occurredDate.displayString)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)

                    if !row.sourceBadgeText.isEmpty {
                        sourceBadge(row.sourceBadgeText)
                    }

                    Spacer(minLength: 0)

                    Text("剩余 \(row.remainingDays) 天")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(row.isExpiringSoon ? Theme.Semantic.danger : .secondary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    private func sourceBadge(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Theme.Spacing.xxs)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule(style: .continuous))
    }

    private var emptyState: some View {
        EmptyStateView(
            iconName: "trash",
            title: "没有最近删除的账目",
            message: "删除的账目会在这里保留 \(TrashService.retentionDays) 天"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("trash.empty")
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.4)

            Button(role: .destructive) {
                showsPurgeAllConfirmation = true
            } label: {
                Text("全部彻底删除")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
            }
            .buttonStyle(.bordered)
            .tint(Theme.Semantic.danger)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityIdentifier("trash.purgeAll")
        }
        .background(.bar)
    }

    // MARK: - 动作

    private func purgeAll() {
        do {
            let removed = try viewModel.purgeAll()
            toast = ToastItem(message: removed > 0 ? "已彻底删除 \(removed) 条" : "回收站已经是空的")
        } catch {
            toast = ToastItem(message: "彻底删除失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 预览

#Preview("最近删除") {
    if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
        NavigationStack {
            TrashView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    } else {
        Text("预览数据不可用")
    }
}
