//
//  RootTabView.swift
//  一账 / App
//
//  职责：4 个 Tab 的根视图。每个 Tab 独立 `NavigationStack`（切换 Tab 不丢栈）。
//
//  为什么每个 Tab 各自一个 NavigationStack（而不是套在最外层）：
//  套在最外层会让"账本里的二级页"在切到待办后仍然压着导航栏——
//  用户从待办回来会看到自己还在账目详情页里，这是 iOS 原生 App 不会有的行为。
//  各 Tab 独立栈 + `TabView` 默认保留各 Tab 的视图状态，才是正确的手感。
//
//  本文件只负责"骨架与导航结构"，不随页面重写而改动：
//  订阅页已是真实页面（T12），账本 / 待办 / 我的仍是占位，由后续任务逐个替换。
//

import SwiftUI

/// 四个 Tab。
enum AppTab: String, Hashable {
    case ledger
    case todo
    case subscription
    case settings

    /// Tab 标题。
    var title: String {
        switch self {
        case .ledger: return "账本"
        case .todo: return "待办"
        case .subscription: return "订阅"
        case .settings: return "我的"
        }
    }

    /// Tab 图标（SF Symbols）。
    var systemImage: String {
        switch self {
        case .ledger: return "list.bullet.rectangle"
        case .todo: return "checklist"
        case .subscription: return "arrow.triangle.2.circlepath"
        case .settings: return "person.crop.circle"
        }
    }
}

/// 根 Tab 视图。
struct RootTabView: View {

    @Environment(AppEnvironment.self) private var environment

    @State private var selection: AppTab = RootTabView.initialTab

    /// 启动时默认选中的 Tab。
    ///
    /// 只服务开发期验证与 QA 复现（`UserDefaults` 会自动读取 `-Key value` 形式的启动参数）：
    /// ```sh
    /// xcrun simctl launch booted com.xiaoban.yizhang -YIZHANG_INITIAL_TAB subscription
    /// ```
    /// Release 构建里这段被 `#if DEBUG` 摘掉，恒为「账本」。
    private static var initialTab: AppTab {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "YIZHANG_INITIAL_TAB"),
           let tab = AppTab(rawValue: raw) {
            return tab
        }
        #endif
        return .ledger
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                LedgerHomeView()
            }
            .tabItem { Label(AppTab.ledger.title, systemImage: AppTab.ledger.systemImage) }
            .tag(AppTab.ledger)

            NavigationStack {
                TodoListView()
            }
            .tabItem { Label(AppTab.todo.title, systemImage: AppTab.todo.systemImage) }
            .tag(AppTab.todo)

            NavigationStack {
                SubscriptionListView()
            }
            .tabItem { Label(AppTab.subscription.title, systemImage: AppTab.subscription.systemImage) }
            .tag(AppTab.subscription)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
            .tag(AppTab.settings)
        }
        // 任何页面把 `environment.selectedTab` 改掉，这里跟着切。
        // 单向（外部改 → 本地 State），用户点 Tab 只改本地 State，
        // 不反过来回写 environment，避免两处状态互相触发形成抖动。
        .onChange(of: environment.selectedTab) { _, newValue in
            if selection != newValue { selection = newValue }
        }
        .onChange(of: selection) { _, newValue in
            if environment.selectedTab != newValue { environment.selectedTab = newValue }
        }
        .task {
            #if DEBUG
            // 首帧之后的一轮 runloop 才算是"可交互"
            await Task.yield()
            PerfProbe.markFirstFrameIfRequested()
            #endif
        }
    }
}
