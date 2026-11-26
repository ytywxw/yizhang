//
//  PendingReviewView.swift
//  一账 / Features / Ledger
//
//  职责：订阅账目「待确认」的核对页（V1.1 F-SUB-13）——一次看全所有还没核对的账目。
//
//  三个刻意的决定：
//  ① **底部只有「全部确认」**（PRD §8-2）：否定是逐笔判断，一次误触否掉 10 期扣费
//     无法挽回（恢复要走回收站，而回收站里那些账目看起来都一样）。
//     所以「不是这笔」只出现在每一笔自己的行上，绝不做批量。
//  ② **跨月**：待确认窗口是"今天与往前 7 天"，它天然会跨月。
//     若只列当前月，用户从概览卡的「含待确认 3 笔」点进来会看到 2 笔，那是最难解释的 bug。
//     所以数据源是 `LedgerService.pendingEntries()`（全表订阅来源），不是本月列表。
//  ③ **每行带日期**：跨月列表里没有日期就分不清"哪笔是这周的、哪笔是上个月的"，
//     而 `EntryRowView` 在首页是靠分组头提供日期的，这里没有分组头。
//
//  本页不写业务判断：确认走 `LedgerService.confirm`，否定走 `SubscriptionService.denyEntry`。
//

import SwiftUI

/// 待确认核对页。
struct PendingReviewView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// 待确认的账目行（每次写入后重新读取，不做本地状态猜测）。
    @State private var rows: [EntryRowModel] = []

    @State private var errorMessage: String?
    /// 批量确认进行中：防止用户连点两次「全部确认」。
    @State private var isConfirmingAll = false

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Semantic.pageBackground)
            .navigationTitle("待确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .accessibilityIdentifier("pending.close")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
        }
        .task { load() }
        .task(id: environment.dataVersion) {
            // 任何写入提交后自增：别的页面确认/删除了某笔，这里跟着重读
            load()
        }
        .accessibilityIdentifier("pending.root")
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xs) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                hint

                ForEach(rows) { row in
                    card(row)
                }

                Color.clear.frame(height: Theme.Spacing.lg)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("pending.list")
    }

    private var hint: some View {
        Text("这些是订阅自动记下的账。核对一下：是的话点「这是对的」，不是就点「不是这笔」。")
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一笔待确认账目：行 + 两个动作。
    private func card(_ row: EntryRowModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.xxs) {
                Text(row.day.fullDisplayString)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.xs)

            EntryRowView(row: row)

            Divider()
                .opacity(0.4)
                .padding(.leading, Theme.Spacing.md)

            HStack(spacing: Theme.Spacing.xs) {
                Button {
                    deny(row)
                } label: {
                    Text("不是这笔")
                        .font(Theme.Typography.captionStrong)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Semantic.danger)
                .disabled(isConfirmingAll)
                .accessibilityIdentifier("pending.deny.\(row.id.uuidString)")

                Button {
                    confirm(row)
                } label: {
                    Text("这是对的")
                        .font(Theme.Typography.captionStrong)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Semantic.pending)
                .disabled(isConfirmingAll)
                .accessibilityIdentifier("pending.confirm.\(row.id.uuidString)")
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xs)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
    }

    // MARK: - 底部动作

    /// 底部**只有**「全部确认」。
    ///
    /// 刻意不做「全部否定」（PRD §8-2）：否定的后果是"这一期扣费不再计入"，
    /// 批量误触会把一整段时间的订阅支出全部抹掉，而且没有任何一次点击能被用户看见。
    /// 逐笔否定才是安全的粒度。
    @ViewBuilder
    private var bottomBar: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Divider()

                Button {
                    confirmAll()
                } label: {
                    Text(rows.count == 1 ? "确认这笔" : "全部确认（\(rows.count)）")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Semantic.pending)
                .disabled(isConfirmingAll)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityIdentifier("pending.confirmAll")
            }
            .background(.bar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            EmptyStateView(
                iconName: "checkmark.circle",
                title: "都核对完了",
                message: "没有需要确认的订阅账目。之后订阅自动记账时，7 天内的会在账本里标上「待确认」。"
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Semantic.danger)
                    .padding(.horizontal, Theme.Spacing.md)
            }

            Button("关闭") { dismiss() }
                .font(Theme.Typography.headline)
                .frame(minWidth: 120, minHeight: Theme.minimumTapSize)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    // MARK: - 动作

    /// 重新读取待确认列表。
    private func load() {
        do {
            rows = try environment.ledger.pendingEntries().map(EntryRowModel.init(entry:))
            errorMessage = nil
        } catch {
            errorMessage = "读取失败：\(error.localizedDescription)。关闭后重进可以重试。"
        }
    }

    /// 「这是对的」：pending → confirmed，只改确认状态，不动金额。
    private func confirm(_ row: EntryRowModel) {
        do {
            _ = try environment.ledger.confirm(id: row.id)
            load()
        } catch {
            errorMessage = "确认失败：\(error.localizedDescription)"
        }
    }

    /// 「不是这笔」：软删这笔账 + 抑制该订阅周期（不可回退扣费日）。
    ///
    /// 失败时**不改**列表：账目还在，用户还能再试一次，也不会误以为已经处理完。
    private func deny(_ row: EntryRowModel) {
        do {
            _ = try environment.subscription.denyEntry(id: row.id)
            load()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    /// 「全部确认」：一次事务确认全部，成功后关页（列表已经没有内容了）。
    private func confirmAll() {
        isConfirmingAll = true
        defer { isConfirmingAll = false }

        do {
            let count = try environment.ledger.confirmAll()
            load()
            if count > 0 { dismiss() }
        } catch {
            errorMessage = "全部确认失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 预览

#Preview("待确认") {
    PendingReviewPreview()
}

private struct PendingReviewPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            PendingReviewView()
                .environment(environment)
                .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
        }
    }
}
