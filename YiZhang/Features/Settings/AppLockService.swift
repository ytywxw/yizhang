//
//  AppLockService.swift
//  一账 / Features / Settings
//
//  职责：Face ID / Touch ID 应用锁（T21）——默认关闭，开启前先验证一次，回前台超过 30 秒才要求解锁。
//
//  ## 四个决定
//
//  ① **30 秒宽限期，不是"每次切后台都锁"**：记账过程中切到备忘录看一眼金额再回来
//     是最高频的动作。每次都要人脸识别，用户第三天就会把锁关掉——一个被关掉的锁
//     等于没有锁。30 秒足够覆盖"拿快递 / 看一眼消息"这类短切换。
//  ② **开启前必须验证一次**：不验证就打开，用户可能在没录过人脸的设备上打开开关，
//     下次启动直接把自己锁在外面（数据在本地，谁都救不了）。
//  ③ **不可用时优雅降级**：`canEvaluatePolicy` 为 false（模拟器 / 没设密码 / 没录面容）时
//     开关置灰并给出原因，而不是让用户点开再失败。
//  ④ **协议注入**（`BiometricEvaluating`）：`LAContext` 在模拟器上的行为不可控，
//     30 秒阈值这类逻辑必须能在 0 个系统弹窗的情况下被单测。
//
//  安全边界要诚实：这是**本地防窥**，不是加密。数据仍在 SQLite 里，
//  越狱 / 备份导出能绕开它。V1.0 不承诺"数据加密"，别把 UI 文案写成那个意思。
//

import Foundation
import LocalAuthentication
import SwiftUI

// MARK: - 生物识别抽象

/// 生物识别能力（真实现包 `LAContext`，测试注入 fake）。
@MainActor
protocol BiometricEvaluating: AnyObject {

    /// 设备当前是否可用（有硬件 + 用户已设置密码/面容）。
    var isAvailable: Bool { get }

    /// 「面容 ID」/「触控 ID」/「生物识别」，用于文案。
    var biometryName: String { get }

    /// 发起一次验证。
    /// - Parameter reason: 系统弹窗里的说明文字。
    /// - Returns: 是否通过。
    func evaluate(reason: String) async -> Bool
}

/// 真实实现。
@MainActor
final class LiveBiometricEvaluator: BiometricEvaluating {

    private var context = LAContext()

    var isAvailable: Bool {
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var biometryName: String {
        // 每次新建 context：`biometryType` 只在 `canEvaluatePolicy` 之后才有值
        let probe = LAContext()
        var error: NSError?
        guard probe.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return "生物识别" }
        switch probe.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "光学 ID"
        default: return "设备密码"
        }
    }

    func evaluate(reason: String) async -> Bool {
        let local = LAContext()
        var error: NSError?
        guard local.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            // `.deviceOwnerAuthentication`：生物识别失败时允许退回输密码，
            // 避免"脸没识别出来就永远进不去"
            return try await local.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

// MARK: - 服务

/// 应用锁。
@MainActor
@Observable
final class AppLockService {

    /// 回前台多久之后才要求解锁（秒）。写死成常量，测试与文案都引用它。
    static let gracePeriod: TimeInterval = 30

    /// `UserDefaults` 里的开关键。
    static let enabledKey = "yizhang.appLock.enabled"

    /// 当前是否开启。
    private(set) var isEnabled: Bool

    /// 当前是否处于"已上锁"（UI 据此盖一层遮罩）。
    private(set) var isLocked = false

    /// 最近一次进入后台的时刻。
    private(set) var lastBackgroundedAt: Date?

    @ObservationIgnored
    private let evaluator: BiometricEvaluating

    @ObservationIgnored
    private let defaults: UserDefaults

    /// 指定依赖（测试注入 fake）。
    ///
    /// 注意这里**不写** `= LiveBiometricEvaluator()` 这种默认参数：
    /// 默认参数在非隔离上下文求值，而 `LiveBiometricEvaluator` 是 `@MainActor` 类型，
    /// 写成默认参数会编译报"调用主 actor 隔离的初始化器"。
    init(evaluator: BiometricEvaluating, defaults: UserDefaults = .standard) {
        self.evaluator = evaluator
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: AppLockService.enabledKey)
    }

    /// 生产用初始化器（构造发生在 `@MainActor` 上下文内）。
    convenience init() {
        self.init(evaluator: LiveBiometricEvaluator())
    }

    // MARK: - 能力

    /// 设备能不能用生物识别（不能时开关置灰）。
    var isAvailable: Bool { evaluator.isAvailable }

    var biometryName: String { evaluator.biometryName }

    /// 开关是否可点。
    var canToggle: Bool { isAvailable || isEnabled }

    /// 不可用时的说明（可用时为空）。
    var unavailableHint: String? {
        isAvailable ? nil : "这台设备还没有设置面容 ID 或设备密码，无法开启应用锁。"
    }

    // MARK: - 开关

    /// 打开应用锁：**先验证一次**，通过才落库。
    ///
    /// - Returns: 是否成功打开。
    @discardableResult
    func enable() async -> Bool {
        guard isAvailable else { return false }
        let passed = await evaluator.evaluate(reason: "开启应用锁，先验证一次是你本人")
        guard passed else { return false }
        setEnabled(true)
        isLocked = false
        return true
    }

    /// 关闭应用锁（关闭不验证：能看到这个开关的人已经进来了）。
    func disable() {
        setEnabled(false)
        isLocked = false
    }

    private func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AppLockService.enabledKey)
        isEnabled = enabled
    }

    // MARK: - 生命周期

    /// 记录进入后台的时刻（`.inactive` / `.background` 都会调，重复调用取最早那次）。
    func noteBackgrounded(at moment: Date = Date()) {
        guard isEnabled else { return }
        if lastBackgroundedAt == nil {
            lastBackgroundedAt = moment
        }
    }

    /// 回前台：判断要不要上锁。
    ///
    /// - Returns: 是否已上锁（`true` 时 UI 应盖遮罩并触发 `unlock()`）。
    @discardableResult
    func noteActivated(at moment: Date = Date()) -> Bool {
        guard isEnabled else {
            isLocked = false
            lastBackgroundedAt = nil
            return false
        }
        guard let backgroundedAt = lastBackgroundedAt else {
            // 冷启动：没有"上次后台时刻"就不锁——否则每次打开 App 都要验一次
            return isLocked
        }
        let elapsed = moment.timeIntervalSince(backgroundedAt)
        lastBackgroundedAt = nil
        if elapsed >= AppLockService.gracePeriod {
            isLocked = true
        }
        return isLocked
    }

    /// 解锁（UI 遮罩上的按钮 / 遮罩出现时自动触发一次）。
    ///
    /// - Returns: 是否解锁成功。
    @discardableResult
    func unlock() async -> Bool {
        guard isEnabled, isLocked else {
            isLocked = false
            return true
        }
        let passed = await evaluator.evaluate(reason: "解锁你的账本")
        if passed {
            isLocked = false
        }
        return passed
    }
}

// MARK: - 锁定遮罩

/// 全屏锁定遮罩。
///
/// 为什么这个视图放在服务文件里（而不是单独一个 View 文件）：
/// T21 的文件清单是固定的六个，遮罩与 `AppLockService` 是同一条功能的两个面
/// （一个判断、一个呈现），拆文件反而让"锁逻辑在哪"需要跳两次。
struct AppLockGateView: View {

    let service: AppLockService
    var onUnlock: (() -> Void)?

    @State private var isVerifying = false
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.Semantic.pageBackground
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.md) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)

                Text("一账已锁定")
                    .font(Theme.Typography.title)

                Text("离开超过 \(Int(AppLockService.gracePeriod)) 秒，需要验证 \(service.biometryName) 才能继续。")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)

                Button {
                    Task { await verify() }
                } label: {
                    Text(isVerifying ? "正在验证…" : "解锁")
                        .font(Theme.Typography.headline)
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying)
                .accessibilityIdentifier("appLock.unlock")

                if failed {
                    Text("验证没有通过，可以再试一次")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Semantic.danger)
                }
            }
        }
        .accessibilityIdentifier("appLock.gate")
    }

    private func verify() async {
        isVerifying = true
        failed = false
        let passed = await service.unlock()
        isVerifying = false
        if passed {
            onUnlock?()
        } else {
            failed = true
        }
    }
}
