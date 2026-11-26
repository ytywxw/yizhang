//
//  ExportView.swift
//  一账 / Features / Settings
//
//  职责：数据导出页（T22）——选格式 + 是否带软删 + 生成文件 + 系统分享。
//
//  ## 三个决定
//
//  ① **生成与分享分成两步**：`ShareLink` 需要一个**已经存在**的 URL。
//     如果点"分享"才开始生成，用户会看到一个转圈之后才弹出的分享面板，
//     文件大了还可能超时。所以进页面就生成（后台线程），`ShareLink` 立刻可用；
//     切换格式/开关时重新生成，旧文件被同名覆盖（不累积垃圾）。
//  ② **不用 `FileDocument`**：1 万行 CSV 约 2–3MB，`FileDocument` 会把整包读进内存
//     再交给系统，且 `fileWrapper` 是同步调用。这里直接给系统一个临时文件 URL。
//  ③ **页面上写清"导出的是什么"**：行数、是否含软删、金额单位。
//     导出功能最容易出的问题是"用户以为导出的是全部，其实少了几条"。
//

import SwiftUI

/// 数据导出页。
struct ExportView: View {

    @Environment(AppEnvironment.self) private var environment

    /// 空态里的「去记一笔」：切到账本 Tab（`nil` 时不显示这个空态动作）。
    var onGoToLedger: (() -> Void)?

    @State private var format: ExportFormat = .csv
    @State private var includesDeleted = false
    @State private var fileURL: URL?
    @State private var rowCount = 0
    @State private var isBuilding = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Picker("格式", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("export.format")

                Text(format.hint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView(title: "格式")
            }

            Section {
                Toggle("包含已删除的账目", isOn: $includesDeleted)
                    .accessibilityIdentifier("export.includeDeleted")
            } footer: {
                Text("默认只导出未删除的账目。打开后会把软删的账也导出，CSV 用 `已删除` 列（true / false）标出来，JSON 用 deleted 字段。")
                    .font(Theme.Typography.caption)
            }

            Section {
                if rowCount == 0, !isBuilding, fileURL != nil {
                    // 空库也允许导出（表头齐全，脚本不用特判），但要说清"导出去是空的"，
                    // 否则用户会以为按钮坏了或者数据丢了。
                    EmptyStateView(
                        iconName: "tray",
                        title: "还没有可以导出的账目",
                        message: "先记几笔账，或者把「包含已删除的账目」打开——软删的账也算数据。",
                        actionTitle: "去记一笔",
                        action: { onGoToLedger?() }
                    )
                    .listRowBackground(Color.clear)
                }

                HStack {
                    Text("将导出")
                    Spacer()
                    Text("\(rowCount) 笔")
                        .font(Theme.Typography.amountSmall)
                        .foregroundStyle(.secondary)
                }

                if let fileURL {
                    ShareLink(item: fileURL) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "square.and.arrow.up")
                            Text("分享 \(ExportService.fileName(format: format))")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(Theme.Typography.headline)
                    }
                    .accessibilityIdentifier("export.share")
                } else {
                    Button {
                        Task { await buildFile() }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            if isBuilding {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc.badge.plus")
                            }
                            Text(isBuilding ? "正在生成…" : "生成导出文件")
                        }
                        .font(Theme.Typography.headline)
                    }
                    .disabled(isBuilding)
                    .accessibilityIdentifier("export.build")
                }
            } header: {
                SectionHeaderView(title: "导出")
            } footer: {
                Text("文件写在 App 的临时目录里，通过系统分享保存到「文件」或发给别人。CSV 带 UTF-8 BOM 与 CRLF 换行，Excel 直接打开不会乱码。")
                    .font(Theme.Typography.caption)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                }
            }

            Section {
                Text("CSV 列：日期、类型、金额、分类、账户、收款账户、备注、来源、确认状态、已删除、创建时间。其中「已删除」只在打开上面的开关时出现。金额单位是元，两位小数；含逗号、引号、换行的字段会用双引号包起来（Excel 能直接认）。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Text("「确认状态」是 pending / confirmed：pending 表示这笔订阅账目还没核对过。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Text("JSON 里金额是整数分（amountCents），避免浮点误差；每笔都带 confirmation 字段（pending / confirmed）。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderView(title: "字段说明")
            }
        }
        .navigationTitle("导出数据")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await buildFile()
        }
        .onChange(of: format) { _, _ in
            Task { await buildFile() }
        }
        .onChange(of: includesDeleted) { _, _ in
            Task { await buildFile() }
        }
        .accessibilityIdentifier("export.root")
    }

    // MARK: - 生成

    private func buildFile() async {
        isBuilding = true
        defer { isBuilding = false }

        do {
            let payload = try makeRows()
            rowCount = payload.count
            fileURL = try await ExportService.makeFileInBackground(
                rows: payload,
                format: format,
                includesDeletedColumn: includesDeleted,
                // 导出页恒带「确认状态」列（V1.1 F-SUB-13）：用户拿到的文件里
                // 分不清哪几笔是"AI 猜的还没确认"，就会把待确认的金额当成既定事实。
                // 注意这只影响本页；`ExportService.csv` 的默认值仍是 `false`，
                // 默认表头因此逐字等于 `csvHeaderColumns`（已发布契约）。
                includesConfirmationColumn: true
            )
            errorMessage = nil
        } catch {
            fileURL = nil
            errorMessage = "导出失败：\(error.localizedDescription)。换一种格式再试一次。"
        }
    }

    private func makeRows() throws -> [ExportRow] {
        let entries = try environment.readContext.fetch(QueryDescriptors.allEntries())
        let expenseCategories = try environment.readContext.fetch(
            QueryDescriptors.categories(of: .expense, includeHidden: true)
        )
        let incomeCategories = try environment.readContext.fetch(
            QueryDescriptors.categories(of: .income, includeHidden: true)
        )
        let categories = expenseCategories + incomeCategories
        let accounts = try environment.readContext.fetch(QueryDescriptors.accounts())

        let categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.displayName) })

        return ExportService.rows(
            from: entries,
            categoryNames: categoryNames,
            accountNames: accountNames,
            includesDeleted: includesDeleted
        )
    }
}

// MARK: - 预览

#Preview("导出数据") {
    if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
        NavigationStack {
            ExportView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    } else {
        Text("预览数据不可用")
    }
}
