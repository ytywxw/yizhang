//
//  ScenePhaseCoordinator.swift
//  一账 / App
//
//  职责：把 `scenePhase` 的变化翻译成"该跑的活儿"——冷启动 / 回前台的结算扫描、
//  以及首启一次的一致性自检。
//
//  为什么这件事必须集中在一处（架构 §5.1 / R-SUB-2）：
//  订阅生成账目的触发时机有三个（冷启动、回前台、进入订阅/账本 Tab），三者共用同一套
//  "结算扫描"流程。若三处各写一遍，最容易出现的 bug 是"冷启动扫了、回前台没扫"，
//  用户切出去再回来就看不到新账，且极难复现。
//
//  T11 起 `sweepIfNeeded()` 已接到真实的 `SweepCoordinator`：本类只管"什么时候扫"，
//  业务规则（生成条件、补漏、24 上限）全部在 `SweepPlanner` 里，纯函数、可独立单测。
//  T23 起 `runDiagnosticsIfNeeded()` 接到 `Diagnostics`：每进程一次，
//  DEBUG 自动修重复幂等键，Release 只记录。
//

import Foundation
import SwiftUI

/// scenePhase 协调器。
@MainActor
final class ScenePhaseCoordinator {

    /// 弱引用回指：`AppEnvironment` 持有本对象，本对象不能强持有它（否则循环引用）。
    private weak var environment: AppEnvironment?

    /// 进程内是否已跑过启动自检（T23 接线后用于"只跑一次"）。
    private var hasRunStartupChecks = false

    /// 是否正在扫描（防止 scenePhase 抖动导致并发扫描）。
    private var isSweeping = false

    /// 是否正在重算通知（同上）。
    private var isRescheduling = false

    /// 最近一次自检的一行结论（DEBUG 日志 / 排查用）。
    private(set) var lastDiagnosticsSummary: String?

    init(environment: AppEnvironment? = nil) {
        self.environment = environment
    }

    /// 由 `AppEnvironment.init` 在自身构造完成后调用（此时才能安全弱引用）。
    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - 入口

    /// 处理 scenePhase 变化。
    ///
    /// - Parameter phase: 新的场景阶段。
    func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // 冷启动与"回前台"都会走到这里：`@Environment(\.scenePhase)` 首次即为 .active
            Task { await sweepIfNeeded() }
            // 通知重算与扫描**并行**（T20）：两者的输入互不相干——
            // 扫描读的是 `nextBillingDay`，通知排的也是 `nextBillingDay` 与待办截止日，
            // 扫描新写出来的那笔账目不会改变任何一条通知的内容。
            // 所以不必串行，串行只会让回前台多等一次数据库事务。
            Task { await rescheduleNotificationsIfNeeded() }
            // 启动自检（T23）：进程内只跑一次，与上面两件事并行
            Task { await runDiagnosticsIfNeeded() }
        case .inactive, .background:
            // V1.0 不做后台任务（R-SUB-9）：没有需要在这里收尾的工作
            break
        @unknown default:
            break
        }
    }

    // MARK: - 结算扫描（T11 接线）

    /// 订阅结算扫描。
    ///
    /// 这里只做并发保护（`isSweeping`）；真正的两阶段扫描在 `SweepCoordinator` 内部：
    /// 读候选 → 纯函数算计划 → 在 MainActor 一次 `save()` 原子提交。
    func sweepIfNeeded() async {
        guard environment != nil, !isSweeping else { return }
        isSweeping = true
        // 无论扫描成功还是抛错，都必须复位标志，否则后续 scenePhase 变化会被永久挡住
        defer { isSweeping = false }

        await performSweep()
    }

    // MARK: - 通知重算（T20 接线）

    /// 冷启动 / 回前台重算本地通知。
    ///
    /// 与扫描并列而不是串在扫描后面：通知晚几百毫秒注册没有任何影响，
    /// 但若排在扫描之后，一次慢扫描会连带把提醒也拖晚（用户可能已经离开页面）。
    /// 幂等由 `NotificationService` 保证（全量 `removeAll` + 固定 ID 重排）。
    func rescheduleNotificationsIfNeeded() async {
        guard let environment, !isRescheduling else { return }
        isRescheduling = true
        defer { isRescheduling = false }
        await environment.rescheduleNotifications()
    }

    /// 真正的扫描动作。
    ///
    /// 两阶段由 `SweepCoordinator` 内部完成（读候选 → 纯函数算计划 → MainActor 单事务提交），
    /// 这里只负责"什么时候扫"与"不要并发扫"，业务规则一概不碰。
    private func performSweep() async {
        guard let environment else { return }
        _ = environment.sweep.sweep()
    }

    // MARK: - 启动自检（T23 接线）

    /// 启动自检（进程内只跑一次）。
    ///
    /// `Diagnostics.run` 内部：`detect`（纯读）+ `#if DEBUG` 的 `repair`（只修重复幂等键）。
    /// Release 构建里 `repair` 那段代码根本不存在——发布版**永远不会改用户数据**。
    ///
    /// 为什么只跑一次：它是"启动体检"，不是每小时巡逻。真要持续监控，
    /// 代价是全表扫（1 万行 ~5ms），而为一个已经通过的检查反复扫没有任何收益。
    func runDiagnosticsIfNeeded() async {
        guard let environment, !hasRunStartupChecks else { return }
        hasRunStartupChecks = true

        guard let report = environment.runDiagnostics() else {
            lastDiagnosticsSummary = "自检未能完成（数据库不可读）"
            return
        }
        lastDiagnosticsSummary = report.summary
        #if DEBUG
        print("[Diagnostics] \(report.summary)")
        #endif
    }
}
