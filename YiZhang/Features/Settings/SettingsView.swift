//
//  SettingsView.swift
//  一账 / Features / Settings
//
//  职责：「我的」页（T21）——账户 / 分类 / 统计与数据 / 通知 / 安全 / 关于。
//
//  ## 排布顺序是有理由的
//
//  「账户 → 分类 → 数据 → 通知 → 安全 → 关于」：前两项是**用户天天会改的东西**，
//  放最上面；通知与安全是**设一次就不动**的，往下沉；关于永远最后。
//  把"关于"放首屏是 PC 时代留下来的坏习惯，手机上没人想看版本号。
//
//  ## 每行都带"现在是什么状态"
//
//  「账户 · 5 个」「分类 · 19 个」「应用锁 · 已关闭」——设置页最常见的问题是
//  用户点进去才发现"哦原来这里能改这个"。右侧的当前值就是这个问题的答案。
//
//  通知区块复用 T20 的 `NotificationSettingsSection`（它自己管权限文案与跳系统设置）。
//

import SwiftUI

/// 「我的」页。
struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var accountCount = 0
    @State private var categoryCount = 0
    @State private var lockError: String?
    @State private var toast: ToastItem?

    /// 三个二级页的 push 状态。
    ///
    /// 用 `navigationDestination(isPresented:)` 而不是 `NavigationLink { }`：
    /// 这样无头截图时可以用启动参数把页面推到指定状态（合成点击在 simctl 里做不到）。
    @State private var showsAccounts = false
    @State private var showsCategories = false
    @State private var showsExport = false
    /// DEBUG 截图用：需要把列表滚到哪一段。
    @State private var demoScrollAnchor: String?

    /// App 版本（`MARKETING_VERSION` + build 号）。
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollViewReader { proxy in
            settingsList
                .task(id: demoScrollAnchor) {
                    guard let anchor = demoScrollAnchor else { return }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation { proxy.scrollTo(anchor, anchor: .center) }
                }
        }
    }

    private var settingsList: some View {
        List {
            Section {
                Button {
                    showsAccounts = true
                } label: {
                    settingsRow(
                        icon: "creditcard",
                        title: "账户",
                        detail: "\(accountCount) 个"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.accounts")

                Button {
                    showsCategories = true
                } label: {
                    settingsRow(
                        icon: "square.grid.2x2",
                        title: "分类",
                        detail: "\(categoryCount) 个"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.categories")
            } header: {
                SectionHeaderView(title: "记账设置")
            } footer: {
                Text("账户余额自动计算；分类支持隐藏与排序，预置分类不可删除。")
                    .font(Theme.Typography.caption)
            }

            Section {
                Button {
                    showsExport = true
                } label: {
                    settingsRow(icon: "square.and.arrow.up", title: "导出数据", detail: "CSV / JSON")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.export")
            } header: {
                SectionHeaderView(title: "统计与数据")
            } footer: {
                Text("导出的文件通过系统分享保存到「文件」App，或直接发给自己。")
                    .font(Theme.Typography.caption)
            }

            NotificationSettingsSection()

            Section {
                Toggle(isOn: Binding(
                    get: { environment.appLock.isEnabled },
                    set: { wantEnabled in
                        Task { await applyLockChange(wantEnabled) }
                    }
                )) {
                    settingsRow(
                        icon: "faceid",
                        title: "应用锁",
                        detail: environment.appLock.isEnabled
                            ? "已开启（\(environment.appLock.biometryName)）"
                            : "已关闭",
                        showsChevron: false
                    )
                }
                .disabled(!environment.appLock.canToggle)
                .accessibilityIdentifier("settings.appLock")

                if let hint = environment.appLock.unavailableHint {
                    Text(hint)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                if let lockError {
                    Text(lockError)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                }
            } header: {
                SectionHeaderView(title: "安全")
            } footer: {
                Text("开启后，从后台回到 App 超过 \(Int(AppLockService.gracePeriod)) 秒需要验证一次。这是本地防窥，数据本身没有加密。")
                    .font(Theme.Typography.caption)
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(versionText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                NavigationLink {
                    privacyStatement
                } label: {
                    Text("隐私说明")
                }

                Link(destination: URL(string: "mailto:ytywxw@qq.com")!) {
                    HStack {
                        Text("联系邮箱")
                        Spacer()
                        Text("ytywxw@qq.com")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionHeaderView(title: "关于")
            }
            .id("about")
        }
        // iOS 26 的悬浮 TabBar 会盖住列表最后一行（实测「联系邮箱」被吃掉一半），
        // 这里补一段底部内容边距，让最后一行能滚到 TabBar 之上。
        .contentMargins(.bottom, 32, for: .scrollContent)
        .navigationTitle("我的")
        .navigationDestination(isPresented: $showsAccounts) {
            AccountManageView()
        }
        .navigationDestination(isPresented: $showsCategories) {
            CategoryManageView()
        }
        .navigationDestination(isPresented: $showsExport) {
            ExportView(onGoToLedger: {
                // 先退出二级页，再切 Tab：否则用户下次回「我的」还停在导出页。
                showsExport = false
                environment.selectedTab = .ledger
            })
        }
        .task {
            refreshCounts()
            openSubScreenIfRequested()
        }
        .onChange(of: environment.dataVersion) { _, _ in
            refreshCounts()
        }
        .toast(item: $toast)
        .accessibilityIdentifier("settings.root")
    }

    // MARK: - 行

    /// 一行设置项。
    ///
    /// 用 `Button` 而不是 `NavigationLink` 之后，系统不再自动给箭头与黑色文字，
    /// 所以这里自己补 chevron + `primary` 色——否则整行会变成蓝色，看起来像网页链接。
    private func settingsRow(
        icon: String,
        title: String,
        detail: String,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Spacing.xs)
            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - 隐私说明

    private var privacyStatement: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("你的账目只在这台设备上")
                    .font(Theme.Typography.headline)
                Text("「一账」不需要注册账号，也不会把你的账目上传到任何服务器。所有数据保存在本机的数据库文件里。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                Text("通知由系统本地调度，不经过网络；应用锁使用系统面容 ID / 触控 ID，App 拿不到你的生物特征数据。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                Text("导出的文件由你自己保管——它包含全部账目，请注意分享对象。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Semantic.pageBackground)
        .navigationTitle("隐私说明")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - DEBUG 截图钩子

    /// `-YIZHANG_OPEN_SETTINGS accounts|categories|export`：无头截图时直接推到二级页。
    private func openSubScreenIfRequested() {
        #if DEBUG
        if let anchor = UserDefaults.standard.string(forKey: "YIZHANG_SCROLL_TO") {
            demoScrollAnchor = anchor
        }
        guard let target = UserDefaults.standard.string(forKey: "YIZHANG_OPEN_SETTINGS") else { return }
        switch target {
        case "accounts": showsAccounts = true
        case "categories", "categories-delete": showsCategories = true
        case "export": showsExport = true
        default: break
        }
        #endif
    }

    // MARK: - 动作

    private func refreshCounts() {
        accountCount = (try? environment.readContext.fetchCount(QueryDescriptors.accounts())) ?? 0
        let expense = (try? environment.readContext.fetchCount(
            QueryDescriptors.categories(of: .expense)
        )) ?? 0
        let income = (try? environment.readContext.fetchCount(
            QueryDescriptors.categories(of: .income)
        )) ?? 0
        categoryCount = expense + income
    }

    /// 打开应用锁要验证一次；关闭不验证。
    private func applyLockChange(_ wantEnabled: Bool) async {
        lockError = nil
        if wantEnabled {
            let enabled = await environment.appLock.enable()
            if !enabled {
                lockError = "没有通过验证，应用锁未开启"
            } else {
                toast = ToastItem(message: "应用锁已开启")
            }
        } else {
            environment.appLock.disable()
            toast = ToastItem(message: "应用锁已关闭")
        }
    }
}

// MARK: - 预览

#Preview("我的") {
    if let environment = try? AppEnvironment(container: ModelContainerFactory.inMemoryForPreview()) {
        NavigationStack {
            SettingsView()
        }
        .environment(environment)
        .modelContainer(environment.container)
    } else {
        Text("预览数据不可用")
    }
}
