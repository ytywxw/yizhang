//
//  TemplateEditorSheet.swift
//  一账 / Features / Entry
//
//  职责：模板的「新建 / 编辑」表单（V1.1 F-ACC-14 / PRD §5.2）。
//
//  两个入口共用本页：
//  ① 「设置 → 记账模板」右上「＋」新建 / 点击某行编辑；
//  ② 记账页长按 chip →「编辑」。
//
//  为什么本页不做校验：`TemplateService.validated(_:)` 已经实现了
//  「名字非空 / ≤20 字 / 备注截断 100 / 金额留空即清零 / 类型收敛到支出收入」这一整套，
//  在这里再写一遍就等于养了两份会分叉的口径。本页只负责**收集** `TemplateDraft`
//  并把服务抛出的中文文案显示出来。
//

import SwiftUI

/// 模板新建 / 编辑表单。
struct TemplateEditorSheet: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// 标题（「新建模板」/「编辑模板」）。
    let title: String

    /// 初始内容。新建传 `TemplateDraft()`，编辑传现有模板的草稿。
    let initialDraft: TemplateDraft

    /// 提交（调用点决定走 `create` 还是 `update`）。抛出的错误文案会显示在本页。
    let onSubmit: (TemplateDraft) throws -> Void

    @State private var draft: TemplateDraft
    @State private var amountText: String
    @State private var categories: [CategoryOption] = []
    @State private var accounts: [AccountOption] = []
    @State private var errorMessage: String?

    init(title: String, initialDraft: TemplateDraft, onSubmit: @escaping (TemplateDraft) throws -> Void) {
        self.title = title
        self.initialDraft = initialDraft
        self.onSubmit = onSubmit
        _draft = State(initialValue: initialDraft)
        _amountText = State(
            initialValue: initialDraft.hasAmount && initialDraft.amount > 0
                ? AmountInput.text(from: Money(cents: initialDraft.amount))
                : ""
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("模板名（必填）", text: $draft.name)
                        .onChange(of: draft.name) { _, newValue in
                            if newValue.count > TemplateService.nameLimit {
                                draft.name = String(newValue.prefix(TemplateService.nameLimit))
                            }
                            errorMessage = nil
                        }
                        .accessibilityIdentifier("template.editor.name")
                } header: {
                    Text("名字")
                } footer: {
                    Text("会显示在记账页的 chip 上，"
                         + "建议写成「午饭」「打车」这种一眼能认出的词。允许同名。")
                }

                Section {
                    Picker("类型", selection: $draft.typeRaw) {
                        Text(EntryType.expense.displayName).tag(EntryType.expense.raw)
                        Text(EntryType.income.displayName).tag(EntryType.income.raw)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("template.editor.type")
                } header: {
                    Text("类型")
                } footer: {
                    Text("模板不支持转账（转账是账户间搬钱，没有「固定组合」可言）。")
                }

                Section {
                    Toggle("记住金额", isOn: $draft.hasAmount)
                        .accessibilityIdentifier("template.editor.hasAmount")

                    if draft.hasAmount {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text("¥")
                                .foregroundStyle(.secondary)
                            TextField("0", text: $amountText)
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                                .accessibilityIdentifier("template.editor.amount")
                        }
                    }
                } header: {
                    Text("金额")
                } footer: {
                    Text("关掉「记住金额」后，点模板只填分类和账户，金额由你每次自己输"
                         + "——咖啡、通勤这类每天都不同价的支出应该关掉。")
                }

                Section {
                    Picker("分类", selection: $draft.categoryID) {
                        Text("不指定").tag(UUID?.none)
                        ForEach(selectableCategories) { option in
                            Label(option.name, systemImage: option.iconName)
                                .tag(UUID?.some(option.id))
                        }
                    }
                    .accessibilityIdentifier("template.editor.category")

                    Picker("账户", selection: $draft.accountID) {
                        Text("不指定").tag(UUID?.none)
                        ForEach(accounts) { option in
                            Label(option.name, systemImage: option.symbolName)
                                .tag(UUID?.some(option.id))
                        }
                    }
                    .accessibilityIdentifier("template.editor.account")
                } header: {
                    Text("分类与账户")
                } footer: {
                    Text("账户归档后，模板仍然可用，只是这一个字段不会被填上。")
                }

                Section {
                    TextField("备注（可选）", text: $draft.note, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: draft.note) { _, newValue in
                            if newValue.count > TemplateService.noteLimit {
                                draft.note = String(newValue.prefix(TemplateService.noteLimit))
                            }
                        }
                        .accessibilityIdentifier("template.editor.note")
                } header: {
                    Text("备注")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                            .accessibilityIdentifier("template.editor.error")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("template.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("template.editor.confirm")
                }
            }
            .task { loadOptions() }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("template.editor.sheet")
    }

    // MARK: - 派生数据

    /// 当前类型可选的分类（支出 / 收入互斥，与记账页同一口径）。
    private var selectableCategories: [CategoryOption] {
        categories.filter { $0.type == draft.type }
    }

    // MARK: - 加载

    private func loadOptions() {
        categories = (try? environment.readContext
            .fetch(QueryDescriptors.categories(of: .expense, includeHidden: false))
            .map(CategoryOption.init)) ?? []
        categories += (try? environment.readContext
            .fetch(QueryDescriptors.categories(of: .income, includeHidden: false))
            .map(CategoryOption.init)) ?? []
        accounts = (try? environment.readContext
            .fetch(QueryDescriptors.accounts(includeArchived: false))
            .map(AccountOption.init)) ?? []

        // 类型切换后若原分类不属于新类型，清掉——否则会存出一个「收入-餐饮」的模板
        if let categoryID = draft.categoryID,
           !selectableCategories.contains(where: { $0.id == categoryID }) {
            draft.categoryID = nil
        }
    }

    // MARK: - 提交

    private func save() {
        var payload = draft
        payload.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasAmount {
            let cents = AmountInput.money(from: amountText)?.cents ?? 0
            payload.amount = cents
        } else {
            amountText = ""
        }

        // 类型收敛在服务层做；这里先把不匹配的分类清掉，避免"选了却填不上"
        if let categoryID = payload.categoryID,
           !selectableCategories.contains(where: { $0.id == categoryID }) {
            payload.categoryID = nil
        }

        do {
            try onSubmit(payload)
            dismiss()
        } catch let error as TemplateError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)。改一下再点保存。"
        }
    }
}

// MARK: - 草稿便捷构造

extension TemplateDraft {

    /// 从值类型模板反推草稿（编辑表单用）。
    init(template: TemplateOption) {
        self.init(
            name: template.name,
            typeRaw: template.type.raw,
            amount: template.amount,
            hasAmount: template.hasAmount,
            note: template.note,
            categoryID: template.categoryID,
            accountID: template.accountID
        )
    }
}
