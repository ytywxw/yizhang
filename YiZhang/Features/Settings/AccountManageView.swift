//
//  AccountManageView.swift
//  一账 / Features / Settings
//
//  职责：账户管理页（T21）——列表（余额 / 归档标签）+ 新建 + 编辑 + 排序 + 删除降级归档。
//
//  三个刻意的界面决定：
//  ① **余额是只读大字**，不给任何输入框：能改的余额一定会和流水对不上（R-ACC-1）；
//  ② **删除走确认弹窗，且弹窗文案由 ViewModel 生成**：有账目时说的是"将改为归档"，
//     而不是"删除后无法恢复"——两句话对应两种完全不同的后果，不能共用一句；
//  ③ **排序用系统的 `EditButton` + `.onMove`**：自绘拖拽在长列表滚动时极易误触，
//     而且辅助技术（VoiceOver 的"重新排序"动作）是系统实现免费给的。
//

import SwiftUI

/// 账户管理页。
struct AccountManageView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var viewModel = AccountManageViewModel()
    @State private var editorTarget: AccountEditorTarget?
    @State private var pendingDelete: AccountManageViewModel.DeletePreview?
    @State private var toast: ToastItem?

    var body: some View {
        List {
            if viewModel.rows.isEmpty {
                Section {
                    EmptyStateView(
                        iconName: "creditcard",
                        title: "还没有账户",
                        message: "建一个账户，记第一笔账时就能选它了。"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(viewModel.rows) { row in
                        Button {
                            editorTarget = .edit(row)
                        } label: {
                            AccountRowView(row: row)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = viewModel.deletePreview(for: row.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                toggleArchive(row)
                            } label: {
                                Label(
                                    row.isArchived ? "取消归档" : "归档",
                                    systemImage: row.isArchived ? "arrow.uturn.backward" : "archivebox"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                    .onMove { indices, destination in
                        guard let source = indices.first else { return }
                        let row = viewModel.rows[source]
                        do {
                            try viewModel.move(id: row.id, toIndex: destination)
                        } catch {
                            toast = ToastItem(message: error.localizedDescription)
                        }
                    }
                } header: {
                    SectionHeaderView(title: "账户", detail: "\(viewModel.rows.count) 个")
                } footer: {
                    Text("余额按期初 + 流水自动计算，不能手动修改。归档账户不再出现在记账选择器里，历史账目保留。")
                        .font(Theme.Typography.caption)
                }
            }
        }
        .navigationTitle("账户")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = .create
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("新建账户"))
                .accessibilityIdentifier("accounts.add")
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .accessibilityIdentifier("accounts.reorder")
            }
        }
        .task {
            viewModel.attach(environment)
        }
        .task(id: environment.dataVersion) {
            // 页面存活期间的**外部写入**（回到前台触发 sweep 落订阅账目、
            // 别的页面改账户）不会经过本视图模型，行里的「N 笔账目」会变旧。
            // 旧计数不只是显示问题：删除时的分支判断也读它。
            viewModel.load()
        }
        .sheet(item: $editorTarget) { target in
            AccountEditorSheet(target: target, viewModel: viewModel) { message in
                toast = ToastItem(message: message)
            }
        }
        .alert(
            "删除账户？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { preview in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button(preview.willArchive ? "改为归档" : "删除", role: .destructive) {
                performDelete(preview)
            }
        } message: { preview in
            Text(preview.message)
        }
        .toast(item: $toast)
        .accessibilityIdentifier("accounts.root")
    }

    private func toggleArchive(_ row: AccountManageViewModel.Row) {
        do {
            if row.isArchived {
                try viewModel.unarchive(id: row.id)
                toast = ToastItem(message: "「\(row.name)」已恢复到记账选择器")
            } else {
                try viewModel.archive(id: row.id)
                toast = ToastItem(message: "「\(row.name)」已归档")
            }
        } catch {
            toast = ToastItem(message: error.localizedDescription)
        }
    }

    private func performDelete(_ preview: AccountManageViewModel.DeletePreview) {
        pendingDelete = nil
        do {
            switch try viewModel.delete(id: preview.id) {
            case .deleted:
                toast = ToastItem(message: "「\(preview.name)」已删除")
            case .archived(let count):
                toast = ToastItem(message: "「\(preview.name)」有 \(count) 笔账目，已改为归档")
            }
        } catch {
            toast = ToastItem(message: error.localizedDescription)
        }
    }
}

// MARK: - 行

/// 账户行：类型图标 + 名称 + 余额 + 归档标签。
struct AccountRowView: View {

    let row: AccountManageViewModel.Row

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityBody
            } else {
                regularBody
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            "\(row.name)，\(row.kind.displayName)，余额 \(row.balance.formatted())"
                + (row.isArchived ? "，已归档" : "")
        ))
    }

    /// AX 字号下「名称 + 已归档 + 余额」并排会把余额截成「-¥4526…」、
    /// 把「已归档」压成一列竖字（T24 截图实测）：余额单独一行、标签跟在名称后换行。
    private var accessibilityBody: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            glyph

            VStack(alignment: .leading, spacing: 2) {
                nameLine
                subtitle
                Text(row.balance.formatted())
                    .font(Theme.Typography.amountSmall)
                    .foregroundStyle(balanceColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    private var regularBody: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: row.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(Theme.Semantic.pageBackground)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text(row.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if row.isArchived {
                        Text("已归档")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Theme.Semantic.pageBackground)
                            )
                    }
                }
                Text(row.kind.displayName + (row.entryCount > 0 ? " · \(row.entryCount) 笔" : " · 还没有账目"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Theme.Spacing.xs)

            Text(row.balance.formatted())
                .font(Theme.Typography.amountSmall)
                .foregroundStyle(row.balanceCents < 0 && !row.isNegativeBalanceExpected
                                 ? Theme.Semantic.danger
                                 : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var glyph: some View {
        Image(systemName: row.symbolName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.Semantic.pageBackground))
            .accessibilityHidden(true)
    }

    private var nameLine: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(row.name)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            if row.isArchived {
                Text("已归档")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.Semantic.pageBackground))
            }
        }
    }

    private var subtitle: some View {
        Text(row.kind.displayName + (row.entryCount > 0 ? " · \(row.entryCount) 笔" : " · 还没有账目"))
            .font(Theme.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var balanceColor: Color {
        row.balanceCents < 0 && !row.isNegativeBalanceExpected ? Theme.Semantic.danger : Color.primary
    }
}

// MARK: - 编辑目标

/// 编辑器目标（新建 / 编辑）。
enum AccountEditorTarget: Identifiable, Hashable {
    case create
    case edit(AccountManageViewModel.Row)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let row): return row.id.uuidString
        }
    }
}

// MARK: - 编辑器

/// 新建 / 编辑账户（表单式 sheet）。
struct AccountEditorSheet: View {

    let target: AccountEditorTarget
    let viewModel: AccountManageViewModel
    var onFinished: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: AccountKind = .cash
    @State private var initialBalanceText = ""
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("比如「招行储蓄卡」", text: $name)
                        .accessibilityIdentifier("account.name")
                }

                Section("类型") {
                    Picker("类型", selection: $kind) {
                        ForEach(AccountKind.allCases, id: \.self) { item in
                            Label(item.displayName, systemImage: item.symbolName).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    HStack {
                        Text("¥")
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $initialBalanceText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("account.initialBalance")
                    }
                } header: {
                    Text("期初余额")
                } footer: {
                    Text("期初余额只参与余额计算，不算收入。余额 = 期初 − 支出 + 收入 − 转出 + 转入。")
                        .font(Theme.Typography.caption)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑账户" : "新建账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("account.save")
                }
            }
            .task {
                loadInitialState()
            }
        }
    }

    private func loadInitialState() {
        guard case .edit(let row) = target else { return }
        name = row.name
        kind = row.kind
        initialBalanceText = Money(cents: row.initialBalanceCents).yuanString
    }

    private func save() {
        let cents = Money.parse(initialBalanceText)?.cents ?? 0
        do {
            switch target {
            case .create:
                try viewModel.create(name: name, kind: kind, initialBalanceCents: cents)
                onFinished("已新建「\(name.trimmingCharacters(in: .whitespacesAndNewlines))」")
            case .edit(let row):
                try viewModel.update(
                    id: row.id,
                    name: name,
                    kind: kind,
                    initialBalanceCents: cents
                )
                onFinished("「\(name.trimmingCharacters(in: .whitespacesAndNewlines))」已保存")
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 预览

#Preview("账户管理") {
    if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
        NavigationStack {
            AccountManageView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    } else {
        Text("预览数据不可用")
    }
}
