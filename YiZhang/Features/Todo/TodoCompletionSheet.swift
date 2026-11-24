//
//  TodoCompletionSheet.swift
//  一账 / Features / Todo
//
//  职责：完成确认条（T18）——「这笔花了多少，记在哪」。
//
//  ## 四条刻意的设计
//
//  ① **1/3 屏，不是全屏**：它问的是一个很小的补充问题，不该把用户从列表里拽走。
//     因此**不用 `NavigationStack`**——那条导航栏会白吃掉 ~50pt，在 1/3 屏上
//     足够把金额输入框挤到屏幕外（第一版就是这么翻车的）。标题就是问题本身。
//  ② **下拽关闭 = 什么都没发生**：待办必须退回 `open`。因为 `complete()` 已经把它
//     置成 done 再返回请求（那是刻意的一步），所以这条路径要显式回滚
//     （`TodoCompletionSheetViewModel.rollbackCompletionIfNeeded()`）。
//  ③ **「完成并记账」在金额为空/0 时置灰**：0 元不是一笔账。想不记账就点「不记账」，
//     两个按钮的语义必须分得开，否则账目表里会出现一堆 0 元记录。
//  ④ **分类/账户用 Menu 而不是网格**：1/3 屏放不下 16 个 chip 的网格，
//     而这两个字段在 90% 的情况下用的是默认值——Menu 一行就能改，且不占竖向空间。
//

import SwiftUI

/// 完成确认条。
struct TodoCompletionSheet: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = TodoCompletionSheetViewModel()
    @FocusState private var isAmountFocused: Bool

    /// 首帧就要用到的请求（`attach` 在 `.task` 里做）。
    private let pendingRequest: TodoCompletionRequest

    /// 关闭回调，携带要展示的一句话（`nil` = 不提示）。
    var onFinished: (String?) -> Void

    init(request: TodoCompletionRequest, onFinished: @escaping (String?) -> Void = { _ in }) {
        _viewModel = State(initialValue: TodoCompletionSheetViewModel())
        self.pendingRequest = request
        self.onFinished = onFinished
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(viewModel.title)
                .font(Theme.Typography.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("todo.completion.title")

            amountField(text: $viewModel.amountText)

            HStack(spacing: Theme.Spacing.xs) {
                categoryMenu
                accountMenu
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Semantic.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            buttons
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Semantic.pageBackground)
        .task {
            viewModel.attach(environment, request: pendingRequest)
            // 没填过预计金额 → 直接聚焦，让用户少点一下
            isAmountFocused = viewModel.isAmountEmpty
        }
        .onDisappear {
            // 下拽 / 点外面关闭：回滚完成状态（幂等，已确认过就什么都不做）
            viewModel.rollbackCompletionIfNeeded()
        }
        // 1/3 屏：这个问题的体量就该这么大
        .presentationDetents([.fraction(0.33)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.Semantic.pageBackground)
        .accessibilityIdentifier("todo.completion")
    }

    // MARK: - 金额

    private func amountField(text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            Text("¥")
                .font(Theme.Typography.amountMedium)
                .foregroundStyle(.secondary)

            TextField("花了多少", text: text)
                .font(Theme.Typography.amountMedium)
                .keyboardType(.decimalPad)
                .focused($isAmountFocused)
                .accessibilityIdentifier("todo.completion.amount")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
    }

    // MARK: - 分类 / 账户（Menu：一行改完，不占竖向空间）

    private var selectedCategoryName: String {
        viewModel.categories.first { $0.id == viewModel.categoryID }?.name ?? "选择分类"
    }

    private var selectedAccountName: String {
        viewModel.accounts.first { $0.id == viewModel.accountID }?.name ?? "选择账户"
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(viewModel.categories) { option in
                Button {
                    viewModel.select(categoryID: option.id)
                } label: {
                    if option.id == viewModel.categoryID {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            menuLabel(icon: "tag", text: selectedCategoryName)
        }
        .accessibilityLabel(Text("分类：\(selectedCategoryName)"))
        .accessibilityIdentifier("todo.completion.category")
    }

    private var accountMenu: some View {
        Menu {
            ForEach(viewModel.accounts) { option in
                Button {
                    viewModel.select(accountID: option.id)
                } label: {
                    if option.id == viewModel.accountID {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            menuLabel(icon: "creditcard", text: selectedAccountName)
        }
        .accessibilityLabel(Text("账户：\(selectedAccountName)"))
        .accessibilityIdentifier("todo.completion.account")
    }

    private func menuLabel(icon: String, text: String) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(text)
                .font(Theme.Typography.caption)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: 36)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
        .foregroundStyle(.primary)
    }

    // MARK: - 按钮

    private var buttons: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button {
                if let message = viewModel.skipEntry() {
                    onFinished(message)
                    dismiss()
                }
            } label: {
                Text("不记账")
                    .font(Theme.Typography.body)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minimumTapSize)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("todo.completion.skip")

            Button {
                if let message = viewModel.confirm() {
                    onFinished(message)
                    dismiss()
                }
            } label: {
                Text("完成并记账")
                    .font(Theme.Typography.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minimumTapSize)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConfirm)
            .accessibilityHint(Text(viewModel.confirmDisabledReason ?? ""))
            .accessibilityIdentifier("todo.completion.confirm")
        }
    }
}

// MARK: - 预览

#Preview("完成确认条") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            TodoCompletionSheet(
                request: TodoCompletionRequest(
                    todoID: UUID(),
                    title: "买菜",
                    estimatedAmount: 8600,
                    hasEstimatedAmount: true,
                    categoryID: nil,
                    accountID: nil,
                    completedAt: Date(),
                    hasExpense: true,
                    repeatRule: .none,
                    didSpawnNextOccurrence: false
                )
            )
            .environment(try! AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()))
        }
}
