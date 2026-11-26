//
//  SaveAsTemplateSheet.swift
//  一账 / Features / Entry
//
//  职责：「存为模板」的命名弹窗（V1.1 F-ACC-14 / PRD §5.3-3）。
//
//  两个入口共用本页：
//  ① 账目详情页「⋯ → 存为模板…」——从一笔**已存在**的账目复制，
//     走 `TemplateService.makeFrom(entryID:name:)`（金额、备注、分类、账户原样搬过来）；
//  ② 记账页 chips 行末尾的「＋ 存为模板」——从**表单当前内容**复制，
//     走 `TemplateService.create(_:)`。
//
//  为什么本页只收 `initialName` + `summary` + 一个 `throws` 闭包：
//  两个入口的**取数方式**完全不同（一个从数据库读，一个从表单读），但"改名 + 确认"
//  这一段是完全一样的。把取数留在调用点，本页就不需要知道账目和表单的任何事，
//  也就不会有人在这里偷偷加一条"顺便保存账目"的逻辑。
//

import SwiftUI

/// 「存为模板」命名弹窗。
struct SaveAsTemplateSheet: View {

    @Environment(\.dismiss) private var dismiss

    /// 默认名（PRD 5.3-3：备注 → 备注为空则分类名）。用户可改。
    let initialName: String

    /// 一句话摘要，说明"到底会存下什么"。
    /// 不显示这个，用户点完「存为模板」再回到记账页，会发现多了一个自己没预期的 chip。
    let summary: String

    /// 保存动作。抛出的 `LocalizedError` 文案会显示在本页（`TemplateError` 三条 + 上限）。
    let onSave: (String) throws -> Void

    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(initialName: String, summary: String, onSave: @escaping (String) throws -> Void) {
        self.initialName = initialName
        self.summary = summary
        self.onSave = onSave
        // 默认名可能来自一条 100 字的备注，这里先按模板名上限截断：
        // 打开弹窗就看到超长红字是最没必要的一次报错。
        _name = State(
            initialValue: String(
                initialName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(TemplateService.nameLimit)
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("模板名", text: $name)
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > TemplateService.nameLimit {
                                name = String(newValue.prefix(TemplateService.nameLimit))
                            }
                            errorMessage = nil
                        }
                        .accessibilityIdentifier("template.saveAs.name")
                } header: {
                    Text("模板名")
                } footer: {
                    HStack(spacing: 0) {
                        Text("以后在记账页点一下就能填好。")
                        Spacer(minLength: Theme.Spacing.xs)
                        Text("\(name.count)/\(TemplateService.nameLimit)")
                            .monospacedDigit()
                    }
                }

                Section {
                    Text(summary)
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("template.saveAs.summary")
                } header: {
                    Text("会存下来的内容")
                } footer: {
                    // PRD 5.1：模板不存日期（日期恒为记账当天）。
                    // 这句话必须写出来：否则用户会以为"存了模板就能一键补昨天的账"。
                    Text("日期不存进模板，每次都用记账当天。模板与已记的账目互不影响，删模板不会删账。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                            .accessibilityIdentifier("template.saveAs.error")
                    }
                }
            }
            .navigationTitle("存为模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("template.saveAs.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("template.saveAs.confirm")
                }
            }
            .task { isNameFocused = true }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("template.saveAs.sheet")
    }

    // MARK: - 动作

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else {
            errorMessage = TemplateError.nameEmpty.errorDescription
            return
        }
        do {
            try onSave(trimmedName)
            dismiss()
        } catch let error as TemplateError {
            // 三条业务错误都有中文文案，直接展示
            errorMessage = error.errorDescription
        } catch let error as LedgerError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "存模板失败：\(error.localizedDescription)。改个名字再试一次。"
        }
    }
}
