//
//  TemplateChipsRow.swift
//  一账 / Features / Entry
//
//  职责：记账页金额区上方的常用模板 chips（V1.1 F-ACC-14 / PRD §5.1）。
//
//  三条刻意的设计：
//  ① **没有模板时整行隐藏**，不做空态占位。记账页是全 App 打开最频繁的一页，
//     一个"还没有模板，去设置里建一个"的空条会永久占掉金额上方的一行高度，
//     而它 99% 的时间都在说同一句话。创建入口在「设置 → 记账模板」，
//     以及账目详情页的「⋯ → 存为模板…」——两处都在"用户刚意识到需要模板"的时机。
//  ② **长按才出编辑 / 删除**：chips 是"点一下就填好"的快捷方式，
//     把编辑/删除做成可见按钮会让误触成本从"填错一次"变成"删掉一个模板"。
//  ③ **金额写进 chip 本身**（`🍚 午饭 ¥25`）：判断要不要点这个 chip 的依据是
//     "今天是不是也 25"，把它藏在点开之后就没意义了。
//

import SwiftUI

/// 常用模板 chips 行。
///
/// 只负责展示与转发事件：填表规则全在 `EntryViewModel.applyTemplate(_:)`，
/// 本文件不判断"模板能不能用"——那属于业务判断（架构 §5.3）。
struct TemplateChipsRow: View {

    /// 已排好序的模板（顺序由 `TemplateService.all()` 决定，这里不重排）。
    let templates: [TemplateOption]

    /// 是否还能再建一个（满 20 时末尾的「＋」置灰）。
    let canCreate: Bool

    /// 逐字段降级的小字（如「模板里的账户已归档」）；nil = 不显示。
    let warning: String?

    /// 模板分类 id → SF Symbol 名（找不到给一个中性图标）。
    let iconName: (UUID?) -> String

    /// 点击 chip：把模板填进表单。
    let onSelect: (TemplateOption) -> Void
    /// 长按 →「编辑」。
    let onEdit: (TemplateOption) -> Void
    /// 长按 →「删除」。
    let onDelete: (TemplateOption) -> Void
    /// 末尾「＋ 存为模板」。
    let onCreate: () -> Void

    var body: some View {
        // 无模板时整行隐藏（连小字一起）——空态不占位
        if !templates.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                chips

                if let noticeText {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .accessibilityHidden(true)
                        Text(noticeText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .accessibilityIdentifier("entry.template.notice")
                }
            }
        }
    }

    // MARK: - 子视图

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(templates) { template in
                    chip(template)
                }
                createChip
            }
            .padding(.horizontal, Theme.Spacing.md)
            // 描边在滚动区里会被裁掉，所以左右各留出半个描边宽度
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("entry.template.row")
    }

    private func chip(_ template: TemplateOption) -> some View {
        Button {
            onSelect(template)
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: iconName(template.categoryID))
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(template.name)
                    .lineLimit(1)
                if let suffix = template.amountSuffix {
                    Text(suffix)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Semantic.cardBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // 视觉高度 32，但点击区必须 44（Theme.minimumTapSize）
        .frame(minHeight: Theme.minimumTapSize)
        .contextMenu {
            Button {
                onEdit(template)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onDelete(template)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(accessibilityLabel(for: template)))
        .accessibilityHint(Text("点了就把模板填进这一笔"))
        .accessibilityIdentifier("entry.template.\(template.name)")
    }

    private var createChip: some View {
        Button {
            onCreate()
        } label: {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                Text("存为模板")
                    .lineLimit(1)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(canCreate ? Color.accentColor : Color.secondary.opacity(0.5))
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        canCreate ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                    )
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.minimumTapSize)
        // 满 20 时置灰且点不动：真正的拦截在 `TemplateService.create`，
        // 这里只是别让用户白填一次表单才发现满了。
        .disabled(!canCreate)
        .accessibilityIdentifier("entry.template.create")
    }

    // MARK: - 派生文案

    /// 小字：满 20 的提示优先于降级提示（满额会挡住"再存一个"这个更急的动作）。
    private var noticeText: String? {
        if !canCreate { return TemplateError.limitReached.errorDescription }
        return warning
    }

    private func accessibilityLabel(for template: TemplateOption) -> String {
        if let suffix = template.amountSuffix {
            return "\(template.name) \(suffix)"
        }
        return template.name
    }
}

// MARK: - 高亮脉冲

extension View {

    /// 模板填过的字段亮一下（0.3s 淡出）。
    ///
    /// 为什么需要：点 chip 之后，若模板只填了分类和账户，用户看到的界面几乎没变化，
    /// 很容易以为"点了没反应"然后去手动点一遍分类——反而把模板填的值覆盖掉。
    func templateFlash(_ isOn: Bool, cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        // 用 overlay 而不是 background：分类宫格 / 账户行本身有底色，
        // 画在下面的高亮看不见。`allowsHitTesting(false)` 保证这层不抢点击。
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(isOn ? 0.12 : 0))
                .allowsHitTesting(false)
        )
        .animation(.easeOut(duration: 0.3), value: isOn)
    }
}
