//
//  CategoryManageView.swift
//  一账 / Features / Settings
//
//  职责：分类管理页（T21）——支出 / 收入两个 Tab 的宫格 + 新建 / 编辑 / 排序 / 隐藏 / 删除迁移。
//
//  ## 四个界面决定
//
//  ① **宫格而不是列表**：分类是"看图找东西"，图标 + 名称的方块比一行行文字快得多，
//     也符合它在记账页的呈现方式（一致性）。
//  ② **预置分类不显示删除按钮，而是显示一句解释**：置灰的按钮会让人一直点，
//     一句"预置分类不可删除，可隐藏"把问题从"为什么不能点"变成"我知道该怎么做了"。
//  ③ **删除有账目的分类时，迁移目标必须显式选**：弹窗里列出同类型分类，
//     不选就不给删（`migratingTo == nil` 时业务层直接抛错）。
//  ④ **拖拽用 `draggable` / `dropDestination`**：iOS 17 上这条路径对触屏与
//     辅助技术都有效，不需要自绘手势；落点直接换算成目标下标交给 ViewModel。
//

import SwiftUI

/// 分类管理页。
struct CategoryManageView: View {

    @Environment(AppEnvironment.self) private var environment

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var viewModel = CategoryManageViewModel()
    @State private var selectedType: EntryType = .expense
    @State private var editorTarget: CategoryEditorTarget?
    @State private var pendingDelete: CategoryDeleteRequest?
    @State private var draggedID: UUID?
    @State private var toast: ToastItem?

    private var rows: [CategoryManageViewModel.Row] {
        viewModel.rows(for: selectedType)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.md) {
                Picker("类型", selection: $selectedType) {
                    Text("支出").tag(EntryType.expense)
                    Text("收入").tag(EntryType.income)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.md)
                .accessibilityIdentifier("categories.type")

                grid

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                        .padding(.horizontal, Theme.Spacing.md)
                }

                Text("拖动能调整顺序。隐藏的分类不再出现在记账选择器里，历史账目仍保留。预置分类不可删除，只能隐藏。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.md)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .background(Theme.Semantic.pageBackground)
        .navigationTitle("分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = .create(selectedType)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("新建分类"))
                .accessibilityIdentifier("categories.add")
            }
        }
        .task {
            viewModel.attach(environment)
            openDemoStateIfRequested()
        }
        .task(id: environment.dataVersion) {
            // 与账户页同理：外部写入（sweep 落的订阅账目）不会经过本视图模型，
            // 分类行里的账目数会变旧，删除时的分支判断也跟着错。
            viewModel.load()
        }
        .sheet(item: $editorTarget) { target in
            CategoryEditorSheet(target: target, type: selectedType, viewModel: viewModel) { message in
                toast = ToastItem(message: message)
            }
        }
        .sheet(item: $pendingDelete) { request in
            CategoryDeleteSheet(
                request: request,
                viewModel: viewModel,
                onFinished: { message in
                    pendingDelete = nil
                    toast = ToastItem(message: message)
                },
                onCancel: { pendingDelete = nil }
            )
        }
        .toast(item: $toast)
        .accessibilityIdentifier("categories.root")
    }

    // MARK: - DEBUG 截图钩子

    /// `-YIZHANG_OPEN_SETTINGS categories-delete`：直接弹出"预置分类不可删"的确认页。
    ///
    /// 为什么需要它：这个"置灰 + 说明"的状态只在有人点到删除时出现，
    /// 而 simctl 合成不了长按菜单——不推一把，验收截图里就永远没有这一屏。
    private func openDemoStateIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.string(forKey: "YIZHANG_OPEN_SETTINGS") == "categories-delete" else {
            return
        }
        guard let preset = viewModel.expenseRows.first(where: { $0.isPreset }) else { return }
        pendingDelete = CategoryDeleteRequest(preview: viewModel.deletePreview(for: preset.id), id: preset.id)
        #endif
    }

    // MARK: - 宫格

    private var grid: some View {
        LazyVGrid(
            // AX 字号下 4 列会把「买菜生鲜」压成「买…」（T24 截图实测）：无障碍字号改 2 列
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Theme.Spacing.sm),
                count: dynamicTypeSize.isAccessibilitySize ? 2 : 4
            ),
            spacing: Theme.Spacing.sm
        ) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                CategoryCell(row: row)
                    .onTapGesture {
                        editorTarget = .edit(row)
                    }
                    .contextMenu {
                        Button {
                            editorTarget = .edit(row)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        Button {
                            toggleHidden(row)
                        } label: {
                            Label(row.isHidden ? "取消隐藏" : "隐藏", systemImage: row.isHidden ? "eye" : "eye.slash")
                        }
                        if row.canDelete {
                            Button(role: .destructive) {
                                pendingDelete = CategoryDeleteRequest(preview: viewModel.deletePreview(for: row.id), id: row.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .draggable(row.id.uuidString) {
                        CategoryCell(row: row)
                            .frame(width: 84)
                            .opacity(0.9)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let first = items.first,
                              let sourceID = UUID(uuidString: first),
                              sourceID != row.id else { return false }
                        performMove(sourceID: sourceID, to: index)
                        return true
                    }
                    .accessibilityIdentifier("category.cell.\(row.name)")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func performMove(sourceID: UUID, to index: Int) {
        do {
            try viewModel.move(id: sourceID, toIndex: index, type: selectedType)
        } catch {
            toast = ToastItem(message: error.localizedDescription)
        }
    }

    private func toggleHidden(_ row: CategoryManageViewModel.Row) {
        do {
            try viewModel.setHidden(!row.isHidden, for: row.id)
            toast = ToastItem(message: row.isHidden ? "「\(row.name)」已恢复显示" : "「\(row.name)」已隐藏")
        } catch {
            toast = ToastItem(message: error.localizedDescription)
        }
    }
}

// MARK: - 格子

/// 一个分类格子：图标 + 名称 + 该分类账目数。
struct CategoryCell: View {

    let row: CategoryManageViewModel.Row

    var body: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            CategoryGlyph(
                iconName: row.iconName,
                colorHex: row.colorHex,
                size: .medium
            )
            .overlay(alignment: .topTrailing) {
                if row.isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(Circle().fill(Theme.Semantic.cardBackground))
                        .offset(x: 4, y: -4)
                }
            }

            Text(row.name)
                .font(Theme.Typography.caption)
                .foregroundStyle(row.isHidden ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(row.entryCount > 0 ? "\(row.entryCount) 笔" : "—")
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.name)，\(row.entryCount) 笔\(row.isHidden ? "，已隐藏" : "")"))
    }
}

// MARK: - 编辑器目标

enum CategoryEditorTarget: Identifiable, Hashable {
    case create(EntryType)
    case edit(CategoryManageViewModel.Row)

    var id: String {
        switch self {
        case .create(let type): return "create.\(type.raw)"
        case .edit(let row): return row.id.uuidString
        }
    }
}

// MARK: - 编辑器

/// 新建 / 编辑分类：名称 + 40 个内置图标 + 12 色。
struct CategoryEditorSheet: View {

    let target: CategoryEditorTarget
    let type: EntryType
    let viewModel: CategoryManageViewModel
    var onFinished: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var iconName = PresetCatalog.symbolNames.first ?? "circle"
    @State private var colorHex = PresetCatalog.brandColors.first?.lightHex ?? PresetCatalog.fallbackColorHex
    @State private var errorMessage: String?

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var isPreset: Bool {
        if case .edit(let row) = target { return row.isPreset }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CategoryGlyph(iconName: iconName, colorHex: colorHex, size: .large)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("名称") {
                    TextField("比如「咖啡」", text: $name)
                        .accessibilityIdentifier("category.name")
                }

                Section("图标") {
                    iconGrid
                }

                Section("颜色") {
                    colorRow
                }

                if isPreset {
                    Section {
                        Text("预置分类不可删除，可以隐藏。名称与图标仍可修改。")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑分类" : "新建分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("category.save")
                }
            }
            .task {
                loadInitialState()
            }
        }
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.xs), count: 8), spacing: Theme.Spacing.xs) {
            ForEach(PresetCatalog.symbolNames, id: \.self) { symbol in
                Button {
                    iconName = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 16))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(symbol == iconName ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(symbol == iconName ? Theme.categoryColor(hex: colorHex) : Theme.Semantic.pageBackground)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(symbol))
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var colorRow: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.xs), count: 6), spacing: Theme.Spacing.xs) {
            ForEach(PresetCatalog.brandColors, id: \.key) { color in
                Button {
                    colorHex = color.lightHex
                } label: {
                    Circle()
                        .fill(Theme.categoryColor(hex: color.lightHex))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: color.lightHex == colorHex ? 2 : 0)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(color.displayName))
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private func loadInitialState() {
        switch target {
        case .create:
            break
        case .edit(let row):
            name = row.name
            iconName = row.iconName
            colorHex = row.colorHex
        }
    }

    private func save() {
        do {
            switch target {
            case .create:
                try viewModel.create(
                    name: name,
                    type: type,
                    iconName: iconName,
                    colorHex: colorHex
                )
                onFinished("已新建「\(name.trimmingCharacters(in: .whitespacesAndNewlines))」")
            case .edit(let row):
                try viewModel.update(
                    id: row.id,
                    name: name,
                    iconName: iconName,
                    colorHex: colorHex
                )
                onFinished("「\(name.trimmingCharacters(in: .whitespacesAndNewlines))」已保存")
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 删除

/// 一次删除请求（`DeletePreview` 本身不 `Identifiable`，包一层给 `.sheet(item:)`）。
struct CategoryDeleteRequest: Identifiable {
    let id: UUID
    let preview: CategoryManageViewModel.DeletePreview?

    init(preview: CategoryManageViewModel.DeletePreview?, id: UUID) {
        self.preview = preview
        self.id = id
    }
}

/// 删除确认：预置分类只解释、不迁移；有账目时强制选迁移目标。
struct CategoryDeleteSheet: View {

    let request: CategoryDeleteRequest
    let viewModel: CategoryManageViewModel
    var onFinished: (String) -> Void
    var onCancel: () -> Void

    @State private var targetID: UUID?
    @State private var errorMessage: String?

    private var preview: CategoryManageViewModel.DeletePreview {
        request.preview ?? .direct(name: "")
    }

    private var needsMigration: Bool {
        if case .requiresMigration = preview { return true }
        return false
    }

    private var candidates: [CategoryManageViewModel.Row] {
        let type = viewModel.expenseRows.contains(where: { $0.id == request.id }) ? EntryType.expense : .income
        return viewModel.migrationTargets(for: request.id, type: type)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(preview.message)
                        .font(Theme.Typography.body)
                }

                if case .notAllowed = preview {
                    // 不可删的时候必须给一条出路，否则这个弹窗只是"告诉你不行"。
                    Section {
                        Button {
                            hideInstead()
                        } label: {
                            Label("改为隐藏", systemImage: "eye.slash")
                        }
                        .accessibilityIdentifier("category.delete.hideInstead")
                    }
                }

                if needsMigration {
                    Section("迁移到") {
                        ForEach(candidates) { candidate in
                            Button {
                                targetID = candidate.id
                            } label: {
                                HStack(spacing: Theme.Spacing.sm) {
                                    CategoryGlyph(iconName: candidate.iconName, colorHex: candidate.colorHex, size: .small)
                                    Text(candidate.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if targetID == candidate.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Semantic.danger)
                    }
                }
            }
            .navigationTitle("删除分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("删除", role: .destructive) { performDelete() }
                        .disabled(!preview.canProceed || (needsMigration && targetID == nil))
                        .accessibilityIdentifier("category.delete.confirm")
                }
            }
        }
    }

    /// 预置分类不能删，那就把它隐藏（这正是"可隐藏不可删"的落地动作）。
    private func hideInstead() {
        do {
            try viewModel.setHidden(true, for: request.id)
            onFinished("已隐藏分类，可在分类页取消隐藏")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performDelete() {
        do {
            let outcome = try viewModel.delete(id: request.id, migratingTo: targetID)
            switch outcome {
            case .deleted:
                onFinished("已删除分类")
            case .migrated(let count):
                onFinished("已把 \(count) 笔账目迁移走并删除分类")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 预览

#Preview("分类管理") {
    if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
        NavigationStack {
            CategoryManageView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    } else {
        Text("预览数据不可用")
    }
}
