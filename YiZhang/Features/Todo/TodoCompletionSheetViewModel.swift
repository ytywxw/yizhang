//
//  TodoCompletionSheetViewModel.swift
//  一账 / Features / Todo
//
//  职责：完成确认条（T18）——「这笔花了多少，记在哪」。
//
//  ## 这个文件里最重要的一件事：下拽取消必须回滚完成状态
//
//  `TodoService.complete()` 会**先把状态置 done** 再返回请求（这是刻意的：
//  用户勾选框那一下的意图不可丢，App 被杀也只是"完成了但没记账"）。
//  于是"确认条弹出后用户下拽关掉"这条路径不能什么都不做——那样待办会
//  永远停在"已完成但没记账"，而用户从没确认过任何事。
//
//  所以本 VM 提供 `rollbackCompletionIfNeeded()`：**幂等**地判断"用户到底给过答案没有"，
//  没给过就 `reopen(id:keepEntry:true)` 把状态退回 open。`didResolve` 是唯一的判据，
//  由 `confirm()` / `skipEntry()` 置位——这样"确认后自己 dismiss"不会误触发回滚。
//

import Foundation
import Observation
import SwiftData

/// 完成确认条的状态机。
@Observable
@MainActor
final class TodoCompletionSheetViewModel {

    // MARK: - 请求

    /// `complete(id:)` 返回的完成请求（金额预填值、标题、默认分类/账户都在这）。
    private(set) var request: TodoCompletionRequest?

    // MARK: - 可编辑状态

    var amountText: String = ""
    var categoryID: UUID?
    var accountID: UUID?

    // MARK: - 只读数据

    private(set) var categories: [CategoryOption] = []
    private(set) var accounts: [AccountOption] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false

    /// 用户是否已经给过答案（确认记账 / 不记账）。下拽回滚的唯一判据。
    private(set) var didResolve = false

    // MARK: - 依赖

    private var environment: AppEnvironment?

    // MARK: - 初始化

    init() {}

    // MARK: - 加载

    /// 注入依赖并预填表单。
    func attach(_ environment: AppEnvironment, request: TodoCompletionRequest) {
        self.environment = environment
        self.request = request

        do {
            categories = try environment.readContext
                .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
                .map(CategoryOption.init)
            accounts = try environment.readContext
                .fetch(QueryDescriptors.accounts(includeArchived: false))
                .map(AccountOption.init)
            errorMessage = nil
        } catch {
            errorMessage = "读取分类和账户失败：\(error.localizedDescription)。关掉重新打开可以重试。"
        }

        // 预填：填过预计金额才预填；没填过就留空并聚焦（R-TODO-1）
        amountText = request.suggestedAmount.map { AmountInput.text(from: $0) } ?? ""
        categoryID = request.categoryID ?? categories.first?.id
        accountID = request.accountID ?? accounts.first?.id
        isLoaded = true
    }

    // MARK: - 派生

    /// 标题：「『买菜』完成了吗？」
    var title: String {
        guard let request else { return "完成了吗？" }
        return "「\(request.title)」完成了吗？"
    }

    /// 待办标题（按钮文案里要用）。
    var todoTitle: String {
        request?.title ?? "这条待办"
    }

    /// 金额输入是否为空。
    var isAmountEmpty: Bool {
        amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 解析出的金额（分）。
    var amount: Money? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AmountInput.money(from: trimmed)
    }

    /// 「完成并记账」是否可用：金额必须 > 0（0 元等同于不记账，不该走这个按钮）。
    var canConfirm: Bool {
        guard let amount else { return false }
        return amount.cents > 0 && categoryID != nil && accountID != nil
    }

    /// 主按钮禁用原因（`nil` = 可用）。
    var confirmDisabledReason: String? {
        if isAmountEmpty { return "填个金额才能记账；不想记就选「不记账」" }
        guard let amount else { return "金额格式不对" }
        if amount.cents <= 0 { return "金额要大于 0；不想记就选「不记账」" }
        if categoryID == nil { return "请先创建一个支出分类" }
        if accountID == nil { return "请先创建一个账户" }
        return nil
    }

    // MARK: - 交互

    func select(categoryID newID: UUID) {
        guard categories.contains(where: { $0.id == newID }) else { return }
        categoryID = newID
    }

    func select(accountID newID: UUID) {
        guard accounts.contains(where: { $0.id == newID }) else { return }
        accountID = newID
    }

    // MARK: - 两个出口

    /// 「完成并记账」。
    ///
    /// - Returns: 要展示的一句话（`nil` = 失败，错误已写进 `errorMessage`）。
    @discardableResult
    func confirm() -> String? {
        guard let environment, let request else { return nil }
        guard canConfirm, let amount else {
            errorMessage = confirmDisabledReason
            return nil
        }

        do {
            let outcome = try environment.todo.confirmCompletion(
                CompletionConfirmation(
                    amountCents: amount.cents,
                    categoryID: categoryID,
                    accountID: accountID
                ),
                for: request
            )
            didResolve = true
            if outcome?.wasInserted == true {
                return "已完成，记了一笔 \(amount.formatted())"
            }
            return "已完成"
        } catch let error as TodoError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "这笔账没记上：\(error.localizedDescription)。金额还在输入框里，再点一次完成。"
            return nil
        }
    }

    /// 「不记账」：待办保持完成，库零变化（R-TODO-4）。
    @discardableResult
    func skipEntry() -> String? {
        guard let environment, let request else { return nil }
        do {
            _ = try environment.todo.confirmCompletion(.skipEntry, for: request)
            didResolve = true
            return "已完成，没有记账"
        } catch let error as TodoError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = "这一步没做完：\(error.localizedDescription)。再试一次；如果还是不行，回到列表重新进入。"
            return nil
        }
    }

    /// 下拽 / 点外面关闭：**回滚完成状态**。
    ///
    /// 幂等：`confirm()` / `skipEntry()` 已经给过答案时什么都不做。
    /// 这条路径不抛错也不弹窗——用户就是想取消，报错只会让人更困惑。
    func rollbackCompletionIfNeeded() {
        guard !didResolve, let environment, let request else { return }
        didResolve = true
        try? environment.todo.reopen(id: request.todoID, keepEntry: true)
    }
}
