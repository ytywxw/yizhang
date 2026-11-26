//
//  EntryDetailView.swift
//  一账 / Features / Ledger
//
//  职责：账目详情（T09）——大金额 + 分类/账户/日期/备注/创建时间 + 「来自」来源区 + 编辑/删除。
//
//  删除的三条分支（R-SUB-DEL / R-TODO-DEL）是本页的核心复杂度，也是全项目最容易做错的地方：
//  - **手动记账**：软删 + 3 秒撤销。
//  - **来源是订阅**：本批只实现分支 A——软删 + 把该周期写入 `suppressedCycles`，
//    `nextBillingDay` **不回退**。分支 B（硬删 + 日期回退 + 锚定日重置）留给 T14，
//    但三选项 ActionSheet 的结构现在就建好，B 选项标「即将支持」且禁用（不做死按钮）。
//  - **来源是待办**：软删，且**绝不改待办的完成状态**——用户删的是"这笔支出"，
//    不是"这件事没做过"。提示语要把这一点说清楚，否则用户会以为待办被撤销了。
//
//  V1.1 F-SUB-13 的「待确认」也落在本页：订阅账目在 7 天窗口内是 `pending`，
//  顶部出现琥珀色徽标 + 「这是对的」/「不是这笔」两个按钮。否定走的是 A 分支同一条实现
//  （`SubscriptionService.denyEntry`），不是另写一套。
//
//  为什么「撤销」要留在本页 3 秒而不是回列表弹 Toast：
//  详情页是可能从筛选结果、跨月、甚至深链进来的，删完立刻 dismiss 会让 Toast 出现在
//  一个用户没预期的位置（甚至回到一个已经不包含这笔账的列表）。在本页原地变成
//  「已删除 + 撤销」，撤销入口和"删的是哪笔"在同一个视线范围内，比跳转更可靠。
//

import SwiftUI

// MARK: - 详情模型

/// 详情页的值类型快照（View 不直接持有 `@Model`）。
struct EntryDetailModel: Hashable {

    let snapshot: LedgerEntrySnapshot
    let type: EntryType
    let amount: Money
    let categoryName: String
    let iconName: String
    let colorHex: String
    let accountName: String
    let toAccountName: String?

    /// 来源标题（订阅名 / 待办标题）。
    let sourceTitle: String?
    /// 来源对象是否已被删除（`sourceRefID` 悬空）。
    let isSourceDeleted: Bool
    /// 来源名称（用于「来源已删除」时的可读文案）。
    let sourceDisplayName: String
    /// 是否为「待确认」的订阅账目（V1.1 F-SUB-13）。
    let isPending: Bool

    var day: DateOnly { snapshot.occurredDate }
    var note: String { snapshot.note }
    var createdAt: Date { snapshot.createdAt }
    var source: EntrySource { snapshot.source }

    init(entry: LedgerEntry, sourceTitle: String?, isSourceDeleted: Bool) {
        snapshot = LedgerEntrySnapshot(entry: entry)
        type = entry.type
        amount = entry.amountMoney
        accountName = entry.account?.displayName ?? "账户已删除"
        toAccountName = entry.toAccount?.displayName
        sourceDisplayName = entry.source.displayName
        isPending = entry.isPending

        if entry.isTransfer {
            categoryName = "转账"
            iconName = "arrow.left.arrow.right"
            colorHex = PresetCatalog.fallbackColorHex
        } else if let category = entry.category {
            categoryName = category.displayName
            iconName = category.displayIconName
            colorHex = category.colorHex
        } else {
            categoryName = "未分类"
            iconName = "questionmark.circle"
            colorHex = PresetCatalog.fallbackColorHex
        }

        self.sourceTitle = sourceTitle
        self.isSourceDeleted = isSourceDeleted
    }

    /// 账户展示（转账带箭头）。
    var accountText: String {
        if type.isTransfer, let to = toAccountName {
            return "\(accountName) → \(to)"
        }
        return accountName
    }
}

// MARK: - 详情页

/// 账目详情。
struct EntryDetailView: View {

    /// 要展示的账目 id。
    let entryID: UUID

    /// 只读态（V1.1 回收站）：从「最近删除」进来看一条已软删的账目。
    ///
    /// 只读态必须藏掉所有**写入口**，否则用户会在一个"已经删掉的账目"上改数据：
    /// - 工具栏的「编辑」「删除」（编辑一笔回收站里的账，改完它还是在回收站里，
    ///   用户会以为保存失败）；
    /// - 待确认的「这是对的 / 不是这笔」（`confirm` / `deny` 都是写操作，
    ///   `deny` 还会往抑制表里写东西，而它本来就是被删掉的那一笔）；
    /// - 「来自」区的跳转（源对象可能还活着，但从回收站跳进订阅编辑器
    ///   会让人搞不清自己在编辑什么）。
    ///
    /// 底部换成「恢复」/「彻底删除」两个动作，见 `readOnlyBar`。
    ///
    /// 默认值 `false` 是必须的：本页在账本、筛选、深链等七八处被构造，
    /// 没有默认值会让所有既有调用点一起编译失败。
    var isReadOnly: Bool = false

    /// 只读态动作完成后的回传。
    ///
    /// 为什么不自己弹 Toast：恢复成功后本页会立刻 `dismiss()`，
    /// 一个随视图消失的 Toast 等于没提示。结果交给上一页（`TrashView`）去展示。
    var onReadOnlyResult: ((String) -> Void)?

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: EntryDetailModel?
    @State private var isMissing = false
    @State private var errorMessage: String?
    @State private var showsDeleteOptions = false
    /// B 分支的二次确认（硬删不可撤销，必须再问一次）。
    @State private var showsRevertConfirmation = false
    @State private var showsEditor = false
    /// 只读态「彻底删除」的二次确认（不可恢复，必须再问一次）。
    @State private var showsPurgeConfirmation = false
    /// 软删凭据：非 nil 时本页进入「已删除 + 撤销」状态。
    @State private var undoToken: UndoToken?
    /// 这次删除是不是从「不是这笔」（待确认否定）发起的。
    ///
    /// 只影响「已删除」那屏的说明文案：从否定进来的用户没有见过三选项对话框，
    /// 不该被告知"请选另一个选项"。
    @State private var deniedAsPending = false
    /// 「来自」区点开后要展示的来源编辑器（订阅 / 待办）。
    @State private var sourceEditor: SourceEditorRoute?
    /// 「⋯ → 存为模板…」（V1.1 F-ACC-14 / PRD 5.3-3）。
    @State private var showsSaveAsTemplate = false
    /// 存模板成功后的轻提示。
    @State private var toast: ToastItem?

    var body: some View {
        Group {
            if let undoToken {
                deletedState(token: undoToken)
            } else if let model {
                content(model)
            } else if isMissing {
                missingState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Semantic.pageBackground)
        .navigationTitle(isReadOnly ? "已删除的账目" : "账目详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 只读态：底部换「彻底删除」/「恢复」（PRD §6.1）。
            // 判据带上 `undoToken == nil` 是因为删除后的那一屏不该还留着恢复按钮
            // （那时这笔账已经删了，再点「恢复」是自相矛盾的两个状态）。
            if isReadOnly, model != nil, undoToken == nil {
                readOnlyBar
            }
        }
        .toolbar {
            if model != nil, undoToken == nil, !isReadOnly {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("编辑") { showsEditor = true }
                        .accessibilityIdentifier("detail.edit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        requestDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(Theme.Semantic.danger)
                    .accessibilityLabel(Text("删除这笔账"))
                    .accessibilityIdentifier("detail.delete")
                }
                // 「⋯」里目前只有「存为模板…」一项。用 Menu 而不是再加一个图标：
                // 详情页已经有「编辑」+「删除」两个动作，第三个动作再占一个图标位，
                // 右边会挤成一排小图标（iPhone SE 宽度实测会压到标题）。
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showsSaveAsTemplate = true
                        } label: {
                            Label("存为模板…", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text("更多操作"))
                    .accessibilityIdentifier("detail.more")
                }
            }
        }
        .confirmationDialog(
            "彻底删除这笔账？",
            isPresented: $showsPurgeConfirmation,
            titleVisibility: .visible
        ) {
            Button("彻底删除", role: .destructive) {
                purgeFromTrash()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("彻底删除后无法恢复，这笔账会从数据库里移除。")
        }
        .confirmationDialog(
            "删除这笔账？",
            isPresented: $showsDeleteOptions,
            titleVisibility: .visible
        ) {
            Button("只删除这笔账（不再自动生成）", role: .destructive) {
                deleteSubscriptionEntry(rollbackDate: false)
            }
            Button("删这笔账，并让订阅重新生成") {
                showsRevertConfirmation = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这是一笔由订阅自动生成的账目。「只删除这笔账」之后，这一期不会再补回来，但下次扣费日保持不变。")
        }
        .confirmationDialog(
            "永久删除并回退扣费日？",
            isPresented: $showsRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button("永久删除并回退", role: .destructive) {
                deleteSubscriptionEntry(rollbackDate: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这笔账会被永久删除，且下次打开 App 时订阅会重新生成这一期。此操作不可撤销。")
        }
        .sheet(isPresented: $showsEditor) {
            if let model {
                EntrySheetView(editing: model.snapshot, today: DateOnly(Date())) { _ in
                    load()
                }
                .environment(environment)
                .modelContainer(environment.container)
            }
        }
        .sheet(isPresented: $showsSaveAsTemplate) {
            if let model {
                // 走 `makeFrom`：这笔账的金额 / 备注 / 分类 / 账户原样搬进模板，
                // `hasAmount` 跟随原账目（金额 > 0 则记住金额，PRD 5.3-3）。
                SaveAsTemplateSheet(
                    initialName: templateDefaultName(model),
                    summary: templateSummary(model)
                ) { name in
                    let template = try environment.template.makeFrom(
                        entryID: model.snapshot.id,
                        name: name
                    )
                    toast = ToastItem(message: "已存为模板「\(template.displayName)」")
                }
            }
        }
        .toast(item: $toast)
        .sheet(item: $sourceEditor) { route in
            // 两个编辑器自己带 `NavigationStack` 并自己 `dismiss()`，
            // 所以这里只负责"保存/删除之后重读这笔账"——名称可能已经变了。
            switch route {
            case .subscription(let id):
                SubscriptionEditorView(mode: .edit(id), today: DateOnly(Date())) { _ in
                    load()
                }
            case .todo(let id):
                TodoEditorView(mode: .edit(id), today: DateOnly(Date())) { result in
                    // 这里**故意不接撤销**（降级为只显示消息），理由不是"懒"：
                    //
                    // 本页的 `.toast(item:)` 组件本身支持动作按钮（`ToastItem.actionTitle`），
                    // 技术上能挂一个「撤销」。缺的是**窗口的归属**：3 秒撤销窗口住在
                    // `TodoListViewModel` 里（`undoExpiryTask` + `undoWindow` 都是一个实例私有的），
                    // 而本页在账本 Tab，整个层级里没有那个实例。
                    //
                    // 在这里 new 一个 `TodoListViewModel` 只为拿撤销窗口，等于屏幕上出现
                    // 第二个独立的 3 秒计时器：两个窗口各自过期、各自清凭据，谁也管不了谁。
                    // 代价（两个计时器打架、用户点了没反应且无报错）远大于收益
                    // （从账目详情里删关联待办本就是极低频路径）。
                    //
                    // 所以本页只把"删了什么"如实说出来 —— 删除本身已经生效，
                    // 用户想知道系列有没有被停掉，看这条消息就够了。
                    if case .deleted(let message, _) = result {
                        toast = ToastItem(message: message)
                    }
                    // 待办被删 / 改名 / 改了关联，这笔账的「来自」区都可能变，所以要重读。
                    load()
                }
            }
        }
        .task {
            load()
        }
        .task(id: environment.dataVersion) {
            // 别的页面改动了数据（比如首页撤销了删除），这里跟着重读
            guard undoToken == nil else { return }
            load()
        }
        .accessibilityIdentifier("detail.root")
    }

    // MARK: - 内容

    private func content(_ model: EntryDetailModel) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.sm) {
                amountCard(model)
                infoCard(model)
                sourceCard(model)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.md)
                }

                Color.clear.frame(height: Theme.Spacing.lg)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .scrollIndicators(.hidden)
    }

    /// 头部：大金额 + 分类。
    private func amountCard(_ model: EntryDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            // 「待确认」徽标在卡片最顶部（V1.1 F-SUB-13）：
            // 用户点进来的第一眼要能确认"这笔是要我核对的那笔"，
            // 而不是先读到分类和金额、再往下翻找状态。
            //
            // 只读态下徽标**保留**：它描述的是这笔账的状态（恢复之后仍是待确认，
            // PRD 6.3-5），不是动作。只藏掉下面对应的两个按钮。
            if model.isPending {
                pendingBadge
            }

            HStack(spacing: Theme.Spacing.xs) {
                CategoryGlyph(iconName: model.iconName, colorHex: model.colorHex, size: .medium)

                Text(model.categoryName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: Theme.Spacing.xs)

                Text(model.type.displayName)
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule(style: .continuous))
            }

            MoneyText(
                amount: model.amount,
                tone: MoneyText.Tone(type: model.type),
                emphasis: .large,
                showsSign: model.type.isIncome
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            if !model.note.isEmpty {
                Text(model.note)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 「这是对的 / 不是这笔」在只读态**必须隐藏**：两者都是写操作，
            // 而 `deny` 还会往抑制表里写一笔——对一条已经在回收站里的账目做这件事，
            // 语义上说不通（它本来就已经被"否定"掉了）。
            if model.isPending, !isReadOnly {
                pendingActions
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    private var pendingBadge: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            Text("待确认")
                .font(Theme.Typography.captionStrong)
        }
        .foregroundStyle(Theme.Semantic.pending)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, 2)
        .background(
            Theme.Semantic.pending.opacity(0.14),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("这笔账待确认"))
    }

    /// 「这是对的」/「不是这笔」。
    ///
    /// 两个动作的视觉权重是刻意的：确认（琥珀实心）是绝大多数情况，
    /// 否定（红色描边）是少数情况却后果更重——所以它不用实心，避免顺手点掉。
    private var pendingActions: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button {
                deniedAsPending = true
                deleteAndSuppress()
            } label: {
                Text("不是这笔")
                    .font(Theme.Typography.captionStrong)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
            }
            .buttonStyle(.bordered)
            .tint(Theme.Semantic.danger)
            .accessibilityIdentifier("detail.deny")

            Button {
                confirmPendingEntry()
            } label: {
                Text("这是对的")
                    .font(Theme.Typography.captionStrong)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Semantic.pending)
            .accessibilityIdentifier("detail.confirm")
        }
        .padding(.top, Theme.Spacing.xxs)
    }

    /// 明细：账户 / 日期 / 备注 / 创建时间。
    private func infoCard(_ model: EntryDetailModel) -> some View {
        VStack(spacing: 0) {
            infoRow(title: model.type.isTransfer ? "转账" : "账户", value: model.accountText)

            // 备注刻意**不再重复一行**：它已经在金额下方的大字区域显示过，
            // 同一句话在这张卡里出现两次只会让人怀疑"是不是两处不同的内容"
            divider
            infoRow(
                title: "日期",
                value: "\(model.day.fullDisplayString) \(model.day.weekdayName)"
            )

            divider
            infoRow(title: "创建于", value: Self.detailDateFormatter.string(from: model.createdAt))
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// 「来自」区：订阅 / 待办 / 手动。
    private func sourceCard(_ model: EntryDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("来自")
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(.secondary)

            switch model.source {
            case .manual:
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("手动记账")
                        .font(Theme.Typography.body)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)

            case .subscription, .todo:
                sourceRow(model)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Semantic.cardBackground)
        )
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// 「来自」区的一行：源对象还在 → 可点进订阅 / 待办编辑器；源对象已删 → 纯文本。
    ///
    /// 可点性的判据是**三个**：`sourceRefID` 存在（老数据可能缺）+ 源对象没被删
    /// + 当前不是只读态。
    /// 只判断第一个会把「来源已删除」渲染成箭头，用户点进去是个空表单；
    /// 只判断第二个会在缺 `sourceRefID` 时给一个点了没反应的箭头；
    /// 只判断前两个则会在回收站里给出一个通往订阅编辑器的入口——
    /// 用户从一堆已删账目里点进"编辑订阅"，改完发现那笔账还在回收站，只会更困惑。
    @ViewBuilder
    private func sourceRow(_ model: EntryDetailModel) -> some View {
        let iconName = model.source == .subscription ? "arrow.triangle.2.circlepath" : "checklist"
        let title = model.sourceTitle ?? "\(model.sourceDisplayName)（已删除）"

        if model.isSourceDeleted {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text("来源已删除")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(model.sourceDisplayName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: Theme.minimumTapSize)
            .accessibilityIdentifier("detail.source.deleted")
        } else if let referenceID = model.snapshot.sourceRefID, !isReadOnly {
            Button {
                sourceEditor = model.source == .subscription
                    ? .subscription(referenceID)
                    : .todo(referenceID)
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Semantic.transfer)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Theme.minimumTapSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("来自\(title)，轻点打开"))
            .accessibilityIdentifier("detail.source")
        } else {
            // 缺 `sourceRefID` 的历史数据：说明来历，但不给一个点了没反应的箭头
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.minimumTapSize)
            .accessibilityIdentifier("detail.source.plain")
        }
    }

    private func infoRow(title: String, value: String, allowsMultiline: Bool = false) -> some View {
        HStack(alignment: allowsMultiline ? .top : .center, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Text(value)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: allowsMultiline)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: Theme.minimumTapSize)
    }

    private var divider: some View {
        Divider()
            .opacity(0.4)
            .padding(.leading, Theme.Spacing.md)
    }

    // MARK: - 已删除状态（3 秒撤销）

    private func deletedState(token: UndoToken) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            EmptyStateView(
                iconName: "trash",
                title: "已删除这笔账",
                message: deletedMessage
            )

            Button {
                undo(token)
            } label: {
                Text("撤销")
                    .font(Theme.Typography.headline)
                    .frame(minWidth: 120, minHeight: Theme.minimumTapSize)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("detail.undo")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, Theme.Spacing.xl)
        .accessibilityIdentifier("detail.deleted")
    }

    /// 删除后的说明文案：不同来源说不同的话（尤其是待办那条，必须说明状态没变）。
    private var deletedMessage: String {
        guard let model else { return "3 秒内可以撤销。" }
        switch model.source {
        case .manual:
            return "3 秒内可以撤销。"
        case .subscription:
            if deniedAsPending {
                // 从「不是这笔」进来的用户没见过三选项对话框，不能让他去"选另一个选项"
                return "这一期不会再自动补回来，下次扣费日保持不变。3 秒内可以撤销。"
            }
            return "这一期不会再自动补回来，下次扣费日保持不变。想让它重新生成，请选「删这笔账，并让订阅重新生成」。"
        case .todo:
            let title = model.sourceTitle ?? "这条待办"
            return "「\(title)」仍是已完成状态，只是这笔支出不再计入。"
        }
    }

    private var missingState: some View {
        EmptyStateView(
            iconName: "questionmark.folder",
            title: "这笔账已经不在了",
            message: "它可能已经被删除，或者同步还没完成。返回列表看看别的记录。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 只读态（回收站）

    /// 底部动作区：`彻底删除` + `恢复`。
    ///
    /// 视觉权重：`恢复` 是实心主按钮（从回收站进来的人，十个里有九个是想找回），
    /// `彻底删除` 是红色描边（破坏性但不常用）。两个都占满宽度的一半，
    /// 避免"恢复"被挤成一个小按钮、而"彻底删除"变成默认动作。
    private var readOnlyBar: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.4)

            HStack(spacing: Theme.Spacing.sm) {
                Button(role: .destructive) {
                    showsPurgeConfirmation = true
                } label: {
                    Text("彻底删除")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Semantic.danger)
                .accessibilityIdentifier("detail.purge")

                Button {
                    restoreFromTrash()
                } label: {
                    Text("恢复")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapSize)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.restore")
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .background(.bar)
    }

    /// 从回收站恢复这笔账。
    ///
    /// 全部交给 `TrashService.restore`（它会 `unmarkDeleted` + `unsuppress`），
    /// 本页只负责"告诉上一页结果"和"退出本页"——不在视图层补写任何字段，
    /// 否则恢复出来的账目和删除前就不一定一致了（PRD 6.3-1）。
    private func restoreFromTrash() {
        do {
            try environment.trash.restore(entryID)
            onReadOnlyResult?("已恢复")
            dismiss()
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    /// 彻底删除这笔账（不可恢复，调用前已二次确认）。
    private func purgeFromTrash() {
        do {
            try environment.trash.purge(entryID)
            onReadOnlyResult?("已彻底删除")
            dismiss()
        } catch {
            errorMessage = "彻底删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 存为模板（F-ACC-14）

    /// 默认模板名：备注 → 备注为空则分类名（PRD 5.3-3）。
    ///
    /// 这两句与 `TemplateService.makeFrom` 内部的兜底逻辑一致，但**不是重复**：
    /// 服务用的是"传进来的名字为空才兜底"，而弹窗需要**先**显示一个可编辑的默认值。
    /// 用户直接点保存时走的是这里算出来的名字，两边结果相同。
    private func templateDefaultName(_ model: EntryDetailModel) -> String {
        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { return note }
        return model.categoryName
    }

    /// 弹窗里那句"会存下什么"。
    private func templateSummary(_ model: EntryDetailModel) -> String {
        var parts: [String] = [model.type.displayName]
        parts.append(model.amount.conciseText)
        parts.append(model.categoryName)
        parts.append(model.accountText)
        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            parts.append("备注「\(note)」")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 删除

    /// 删除入口：订阅账目要先问清楚"只删这笔"还是"回退扣费日"。
    private func requestDelete() {
        guard let model else { return }
        if model.source == .subscription {
            showsDeleteOptions = true
        } else {
            performSoftDelete()
        }
    }

    /// 手动 / 待办来源：只软删。
    private func performSoftDelete() {
        Task {
            guard let token = await environment.ledger.delete(id: entryID) else {
                errorMessage = "删除失败：这笔账可能已经不存在了"
                return
            }
            undoToken = token
            startUndoTimer()
        }
    }

    /// 订阅来源的删除入口，两条分支语义相反（R-SUB-DEL）。
    ///
    /// - Parameter rollbackDate: `false` = A 分支（软删 + 抑制该周期，日期不回退）；
    ///   `true` = B 分支（硬删 + 回退 `nextBillingDay`，让扫描重新生成这一期）。
    private func deleteSubscriptionEntry(rollbackDate: Bool) {
        if rollbackDate {
            deleteAndRevert()
        } else {
            deleteAndSuppress()
        }
    }

    /// A 分支：软删 + 把该周期写进抑制表；`nextBillingDay` 不动。可 3 秒撤销。
    ///
    /// 两个入口共用这一条实现：工具栏「删除」→「只删除这笔账」，以及待确认行的
    /// 「不是这笔」（V1.1 F-SUB-13）。它们的语义本来就是同一件事
    /// （"这一期我不认，别再补回来"），写成两份迟早会在抑制表的处理上分叉。
    ///
    /// 实现走 `SubscriptionService.denyEntry(id:)` 而不是在这里自己拼
    /// `ledger.delete` + `subscription.suppress`：软删与抑制必须原子地一起发生，
    /// 顺序错了（先抑制后软删）会在中途失败时留下"账目还在、周期已被抑制"的死局。
    private func deleteAndSuppress() {
        Task {
            do {
                guard let token = try environment.subscription.denyEntry(id: entryID) else {
                    errorMessage = "删除失败：这笔账可能已经不存在了"
                    return
                }
                undoToken = token
                startUndoTimer()
            } catch {
                errorMessage = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    /// 「这是对的」（V1.1 F-SUB-13）：`pending` → `confirmed`，只改确认状态。
    private func confirmPendingEntry() {
        do {
            // 返回值 `false` 表示"它已经不是待确认了"（比如在别的页面确认过）——
            // 这不是错误，重读一次让它从界面上消失即可。
            _ = try environment.ledger.confirm(id: entryID)
            load()
        } catch {
            errorMessage = "确认失败：\(error.localizedDescription)"
        }
    }

    /// B 分支：**先硬删，再回退**。顺序是硬的，反了就是 bug：
    ///
    /// - 先回退再硬删 → 中间若发生一次扫描（`ScenePhaseCoordinator` 的冷启动扫描、
    ///   或任何 `sweep(force:)`），扫描会看到"日期已回到过去 + 幂等键仍在"→ 跳过，
    ///   回退等于白做；
    /// - 先硬删再回退 → 幂等键随记录一起消失，回退后下一次扫描必然能补上这一期。
    ///
    /// 硬删**不可撤销**，所以本分支不给 3 秒撤销入口（对应 R-EDIT-3 的例外）。
    private func deleteAndRevert() {
        guard let model else { return }
        guard environment.ledger.hardDelete(id: entryID) else {
            errorMessage = "删除失败：这笔账可能已经不存在了"
            return
        }
        if let cycleKey = model.snapshot.sourceCycleKey,
           let subscriptionID = model.snapshot.sourceRefID {
            _ = try? environment.subscription.revertCycle(cycleKey: cycleKey, of: subscriptionID)
        }
        undoToken = nil
        dismiss()
    }

    /// 撤销删除：恢复账目（订阅来源还要把抑制表一起回退，否则"撤销"并没有真的回到删除前）。
    private func undo(_ token: UndoToken) {
        guard environment.ledger.undoDelete(token) else {
            errorMessage = "撤销失败，这笔账可能已经被彻底删除"
            undoToken = nil
            return
        }
        if let cycleKey = token.snapshot.sourceCycleKey,
           let subscriptionID = token.snapshot.sourceRefID,
           token.snapshot.source == .subscription {
            _ = try? environment.subscription.unsuppress(cycleKey: cycleKey, of: subscriptionID)
        }
        deniedAsPending = false
        undoToken = nil
        load()
    }

    /// 3 秒后自动退出（撤销入口消失即视为"确定删除"）。
    private func startUndoTimer() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard undoToken != nil else { return }
            undoToken = nil
            dismiss()
        }
    }

    // MARK: - 读取

    /// 重新读取账目与来源信息。
    private func load() {
        do {
            guard let entry = try environment.readContext
                .fetch(QueryDescriptors.entry(id: entryID))
                .first else {
                model = nil
                isMissing = true
                return
            }
            let source = resolveSource(entry)
            model = EntryDetailModel(
                entry: entry,
                sourceTitle: source.title,
                isSourceDeleted: source.isDeleted
            )
            isMissing = false
            errorMessage = nil
        } catch {
            errorMessage = "读取失败：\(error.localizedDescription)。返回上一页再进来可以重试。"
        }
    }

    /// 解析来源对象（订阅 / 待办）。源对象被删除时返回 `isDeleted = true`。
    private func resolveSource(_ entry: LedgerEntry) -> (title: String?, isDeleted: Bool) {
        guard entry.source.needsBadge, let referenceID = entry.sourceRefID else {
            return (nil, false)
        }

        switch entry.source {
        case .manual:
            return (nil, false)
        case .subscription:
            let subscription = try? environment.readContext
                .fetch(QueryDescriptors.subscription(id: referenceID))
                .first
            return (subscription?.displayName, subscription == nil)
        case .todo:
            let todo = try? environment.readContext
                .fetch(QueryDescriptors.todo(id: referenceID))
                .first
            return (todo?.title, todo == nil)
        }
    }

    // MARK: - 工具

    private static let detailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

// MARK: - 来源跳转

/// 「来自」区可以打开的两个来源编辑器。
///
/// 用 `Identifiable` 的 `sheet(item:)` 而不是布尔开关：订阅与待办是两个不同目标，
/// 用布尔量得再存一个 id，两个 `@State` 有可能不同步（id 还是旧的、开关已经 true）。
private enum SourceEditorRoute: Identifiable, Hashable {

    case subscription(UUID)
    case todo(UUID)

    var id: String {
        switch self {
        case .subscription(let id): return "subscription-\(id.uuidString)"
        case .todo(let id): return "todo-\(id.uuidString)"
        }
    }
}

// MARK: - 预览

#Preview("账目详情") {
    EntryDetailPreview()
}

private struct EntryDetailPreview: View {

    var body: some View {
        if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
            NavigationStack {
                EntryDetailView(entryID: UUID())
            }
            .environment(environment)
            .modelContainer(environment.container)
        } else {
            Text("预览数据不可用")
        }
    }
}
