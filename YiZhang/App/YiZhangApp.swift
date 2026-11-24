//
//  YiZhangApp.swift
//  一账 / App
//
//  职责：`@main` 入口——只做三件事：建容器、装配 `AppEnvironment`、把 scenePhase 交给协调器。
//  **不做任何业务判断**（架构 §2「App 层只接线」）。
//
//  失败路径必须存在：容器创建可能因为磁盘损坏 / 迁移失败而抛错。此时不能 `try!` 崩给用户看，
//  而应显示一句人话 + 一个"重试"按钮（重试 = 重建视图树，重启 App 也能恢复）。
//

import SwiftUI
import SwiftData

@main
struct YiZhangApp: App {

    /// 装配结果：成功则持有环境，失败则持有错误文案。
    @State private var environment: AppEnvironment?
    @State private var bootstrapError: String?

    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // 冷启动打点：必须是本文件第一行（见 PerfProbe 文件头的说明）
        PerfProbe.markAppStart()
        #endif
        do {
            let container = try ModelContainerFactory.make()
            let env = try AppEnvironment(container: container)
            _environment = State(initialValue: env)
            _bootstrapError = State(initialValue: nil)
        } catch {
            _environment = State(initialValue: nil)
            _bootstrapError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let environment {
                RootTabView()
                    .environment(environment)
                    .modelContainer(environment.container)
                    // 全 App 固定简体中文：界面文案本来就全是中文，只有系统控件
                    // （`DatePicker` / 键盘候选）会跟随设备语言。不锁的话，
                    // 英文系统上日期会渲染成「Nov 21, 2026」，与「11月21日 周六」并排出现。
                    //
                    // ⚠️ 技术债登记：**V1.0 是单一语言产品**，这一行是"锁死"而不是"本地化"。
                    // V1.2 若做英文界面（PRD §9.3），必须移除本行，改为按 `Bundle` 提供
                    // `zh-Hans` / `en` 两套 `Localizable`，并把硬编码的中文文案抽到资源里。
                    // 在那之前**不要**用这一行去"顺手修"任何区域性格式问题。
                    .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                    .onChange(of: scenePhase) { _, newPhase in
                        environment.sceneCoordinator.handle(newPhase)
                        handleAppLock(phase: newPhase, environment: environment)
                    }
                    // 应用锁遮罩：盖在整棵树之上，`.overlay` 而不是 `.sheet`，
                    // 因为 sheet 会把底下内容缩成卡片——锁屏不该让用户看见账目缩略图。
                    .overlay {
                        if environment.appLock.isLocked {
                            AppLockGateView(service: environment.appLock)
                        }
                    }
            } else {
                BootstrapFailureView(message: bootstrapError ?? "无法打开本地数据库")
            }
        }
    }
}

extension YiZhangApp {

    /// 把 scenePhase 翻译成应用锁的两个动作（T21）。
    ///
    /// - 进后台：记时刻（30 秒宽限期的起点）；
    /// - 回前台：判断是否超时 → 需要则上锁并立刻触发一次验证。
    @MainActor
    private func handleAppLock(phase: ScenePhase, environment: AppEnvironment) {
        switch phase {
        case .active:
            if environment.appLock.noteActivated() {
                Task { await environment.appLock.unlock() }
            }
        case .inactive, .background:
            environment.appLock.noteBackgrounded()
        @unknown default:
            break
        }
    }
}

/// 启动失败页。刻意做成"能自己恢复"的形态：用户点重试或重开 App 都能再试一次。
private struct BootstrapFailureView: View {

    let message: String

    @State private var attempt = 0

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Semantic.danger)

            Text("打开失败")
                .font(Theme.Typography.title)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("重试") {
                // 视图 id 变化会重建装配（容器创建在同一进程内重试一次通常即可恢复）
                attempt += 1
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: Theme.minimumTapSize)
        }
        .id(attempt)
        .padding(Theme.Spacing.lg)
    }
}
