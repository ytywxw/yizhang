//
//  TemplateManageView.swift
//  一账 / Features / Settings
//
//  职责：模板管理页（V1.1 F-ACC-14）——设置 →「记账设置」→ 记账模板。
//
//  ## 三个界面决定
//
//  ① **列表 + 左滑删除 + 系统 `EditButton` 排序**：与「账户」页同一套交互。
//     自绘拖拽在列表滚动时极易误触，而系统 `EditButton` 免费给了 VoiceOver 的
//     「重新排序」动作（无障碍不是附加项）。左滑删除只在非编辑态可用，
//     两种手势互不打架。
//  ② **满 20 时「＋」置灰并把原因写在页脚**：置灰本身不解释原因是常见缺陷，
//     用户会一直点它。页脚那句「最多 20 个模板，先删一个」就是解释。
//  ③ **允许重名**（PRD 5.3-8）：模板是靠 chip 上的图标 + 金额区分的，
//     强行唯一化会让「午饭」这种名字只能有一个，而用户可能真有两个不同分类的午饭。
//

import SwiftUI

/// 模板管理页。
struct TemplateManageView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = TemplateManageViewModel()
    @State private var editorTarget: TemplateEditorTarget?
    @State private var toast: ToastItem?

    var body: some View {
        List {
            if viewModel.isLoaded, viewModel.templates.isEmpty {
                Section {
                    EmptyStateView(
                        iconName: "square.grid.2x2",
                        title: "还没有模板",
                        message: "把「午饭 25 元 餐饮 微信」这类每天重复的组合存成模板，记账时点一下就能填好。"
                    )
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("templates.empty")
                }
            } else {
                Section {
                    ForEach(viewModel.templates) { template in
                        Button {
                            editorTarget = .edit(template)
                        } label: {
                            row(template)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                delete(template)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .accessibilityIdentifier("template.delete.\(template.name)")
                        }
                    }
                    .onMove { indices, destination in
                        viewModel.move(from: indices, to: destination)
                    }
                } header: {
                    SectionHeaderView(title: "模板", detail: viewModel.countText)
                } footer: {
                    footer
                }
            }
        }
        .navigationTitle("记账模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = .create
                } label: {
                    Image(systemName: "plus")
                }
                // 满 20 置灰：真正的拦截在 `TemplateService.create`（抛 `.limitReached`）
                .disabled(!viewModel.canCreate)
                .accessibilityLabel(Text("新建模板"))
                .accessibilityIdentifier("templates.add")
            }
            if viewModel.canReorder {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .accessibilityIdentifier("templates.reorder")
                }
            }
        }
        .task {
            viewModel.attach(environment)
        }
        .task(id: environment.dataVersion) {
            // 记账页的「＋ 存为模板」也会写这张表，本页存活期间要跟着刷新，
            // 否则从详情页存完模板回到这里会看不到新的一条。
            viewModel.load()
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .create:
                TemplateEditorSheet(
                    title: "新建模板",
                    initialDraft: TemplateDraft()
                ) { draft in
                    try viewModel.create(draft)
                    toast = ToastItem(message: "已新建「\(draft.name)」")
                }
            case .edit(let template):
                TemplateEditorSheet(
                    title: "编辑模板",
                    initialDraft: TemplateDraft(template: template)
                ) { draft in
                    try viewModel.update(id: template.id, changing: draft)
                    toast = ToastItem(message: "「\(draft.name)」已保存")
                }
            }
        }
        .toast(item: $toast)
        .accessibilityIdentifier("templates.root")
    }

    // MARK: - 子视图

    private func row(_ template: TemplateOption) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: viewModel.iconName(for: template))
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(Theme.Semantic.pageBackground)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(viewModel.subtitle(for: template))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.xs)

            Text(template.amountSuffix ?? "金额待填")
                .font(Theme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(template.amountSuffix == nil ? .tertiary : .secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel(for: template)))
        .accessibilityIdentifier("template.row.\(template.name)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            if let hint = viewModel.limitHint {
                Text(hint)
                    .foregroundStyle(Theme.Semantic.danger)
                    .accessibilityIdentifier("templates.limitHint")
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.Semantic.danger)
                    .accessibilityIdentifier("templates.error")
            }
            Text("左滑删除，编辑态可拖动排序。模板与已记的账目互不影响：删模板不会删账，改模板也不会改历史。")
                .foregroundStyle(.secondary)
        }
        .font(Theme.Typography.caption)
    }

    // MARK: - 动作

    private func delete(_ template: TemplateOption) {
        do {
            try viewModel.delete(id: template.id)
            toast = ToastItem(message: "已删除「\(template.name)」")
        } catch {
            toast = ToastItem(message: error.localizedDescription)
        }
    }

    private func accessibilityLabel(for template: TemplateOption) -> String {
        let amount = template.amountSuffix ?? "金额待填"
        return "\(template.name)，\(viewModel.subtitle(for: template))，\(amount)"
    }
}

// MARK: - 编辑器目标

/// 新建 / 编辑模板的弹层目标。
///
/// 用一个枚举而不是两个 `@State`：`isPresented` + `templateToEdit` 两个状态
/// 有可能不同步（开关已 true、id 还是上一次的），那类 bug 只在连续操作时出现。
enum TemplateEditorTarget: Identifiable, Hashable {
    case create
    case edit(TemplateOption)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let template): return template.id.uuidString
        }
    }
}

// MARK: - 预览

#Preview("记账模板") {
    if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
        NavigationStack {
            TemplateManageView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    } else {
        Text("预览数据不可用")
    }
}
