//
//  AppLockServiceTests.swift
//  一账Tests / Services
//
//  应用锁的三条规则里有两条是"用错就完蛋"的：
//  ① 设备不支持生物识别时，开关必须置灰而不是"点了才发现"；
//  ② 30 秒宽限期的时间边界（29 秒不验、31 秒要验）——差一秒的 bug
//     用户体感是"我明明刚切出去看了一眼" vs "怎么又要刷脸"，这只能靠测试钉死；
//  ③ 关闭状态下任何时候都不能拦截，否则用户会被自己的设置锁在门外。
//
//  时间不靠 `sleep`：`noteBackgrounded(at:)` / `noteActivated(at:)` 都接受注入的时刻，
//  所以 29 秒和 31 秒是"算出来的"，不是"等出来的"。
//

import XCTest
@testable import YiZhang

// MARK: - Fake 生物识别

@MainActor
private final class FakeBiometricEvaluator: BiometricEvaluating {

    var isAvailable: Bool
    var biometryName: String
    /// 下一次 `evaluate` 的结果。
    var nextResult: Bool
    private(set) var evaluateCount = 0

    init(isAvailable: Bool = true, biometryName: String = "面容 ID", nextResult: Bool = true) {
        self.isAvailable = isAvailable
        self.biometryName = biometryName
        self.nextResult = nextResult
    }

    func evaluate(reason: String) async -> Bool {
        evaluateCount += 1
        return nextResult
    }
}

// MARK: - 测试

@MainActor
final class AppLockServiceTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_795_000_000)

    /// 每个测试用独立的 `UserDefaults`，避免相互污染。
    private func makeDefaults() -> UserDefaults {
        let suite = "yizhang.tests.applock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSUT(
        isAvailable: Bool = true,
        nextResult: Bool = true,
        enabled: Bool = false
    ) -> (service: AppLockService, evaluator: FakeBiometricEvaluator, defaults: UserDefaults) {
        let evaluator = FakeBiometricEvaluator(isAvailable: isAvailable, nextResult: nextResult)
        let defaults = makeDefaults()
        defaults.set(enabled, forKey: AppLockService.enabledKey)
        let service = AppLockService(evaluator: evaluator, defaults: defaults)
        return (service, evaluator, defaults)
    }

    // MARK: - ① 不支持生物识别

    func testUnavailableDeviceCannotEnableLock() async {
        let (service, evaluator, _) = makeSUT(isAvailable: false)

        XCTAssertFalse(service.isAvailable)
        XCTAssertFalse(service.canToggle, "不支持时开关必须置灰")
        XCTAssertNotNil(service.unavailableHint, "置灰的同时要说清为什么")

        let enabled = await service.enable()

        XCTAssertFalse(enabled)
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(evaluator.evaluateCount, 0, "根本不可用就不该去弹验证")
    }

    func testUnavailableButAlreadyEnabledStillAllowsTurningOff() {
        let (service, _, _) = makeSUT(isAvailable: false, enabled: true)

        XCTAssertTrue(service.canToggle, "已经开了的锁必须允许关掉，否则用户被锁在门外")
        service.disable()
        XCTAssertFalse(service.isEnabled)
    }

    // MARK: - ② 30 秒阈值

    func testTwentyNineSecondsDoesNotLock() async {
        let (service, _, _) = makeSUT()
        await service.enable()

        service.noteBackgrounded(at: base)
        let locked = service.noteActivated(at: base.addingTimeInterval(29))

        XCTAssertFalse(locked, "29 秒属于「看一眼就回来」，不该要求验证")
        XCTAssertFalse(service.isLocked)
    }

    func testThirtyOneSecondsLocks() async {
        let (service, _, _) = makeSUT()
        await service.enable()

        service.noteBackgrounded(at: base)
        let locked = service.noteActivated(at: base.addingTimeInterval(31))

        XCTAssertTrue(locked, "31 秒超过宽限期，必须上锁")
        XCTAssertTrue(service.isLocked)
    }

    func testExactlyThirtySecondsLocks() async {
        let (service, _, _) = makeSUT()
        await service.enable()

        service.noteBackgrounded(at: base)
        _ = service.noteActivated(at: base.addingTimeInterval(AppLockService.gracePeriod))

        XCTAssertTrue(service.isLocked, "边界取 >=：正好 30 秒算超时")
    }

    func testColdStartWithoutBackgroundTimeDoesNotLock() async {
        let (service, _, _) = makeSUT(enabled: true)

        let locked = service.noteActivated(at: base)

        XCTAssertFalse(locked, "冷启动没有「上次后台时刻」，不该一打开就要求验证")
    }

    func testBackgroundTimeIsConsumedAfterCheck() async {
        let (service, _, _) = makeSUT()
        await service.enable()

        service.noteBackgrounded(at: base)
        _ = service.noteActivated(at: base.addingTimeInterval(31))
        XCTAssertTrue(service.isLocked)

        // 解锁之后立刻再回前台，不该再次上锁
        await service.unlock()
        XCTAssertFalse(service.isLocked)
        XCTAssertFalse(service.noteActivated(at: base.addingTimeInterval(40)))
    }

    // MARK: - ③ 关闭状态不拦截

    func testDisabledLockNeverBlocksEvenAfterLongBackground() {
        let (service, evaluator, _) = makeSUT(enabled: false)

        service.noteBackgrounded(at: base)
        let locked = service.noteActivated(at: base.addingTimeInterval(3_600))

        XCTAssertFalse(locked)
        XCTAssertFalse(service.isLocked)
        XCTAssertEqual(evaluator.evaluateCount, 0, "关闭状态不该发起任何验证")
    }

    // MARK: - 开关本身

    func testEnableVerifiesBeforeTurningOn() async {
        let (service, evaluator, _) = makeSUT(nextResult: true)

        let enabled = await service.enable()

        XCTAssertTrue(enabled)
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(evaluator.evaluateCount, 1, "开启前必须验证一次")
    }

    func testEnableStaysOffWhenVerificationFails() async {
        let (service, evaluator, defaults) = makeSUT(nextResult: false)

        let enabled = await service.enable()

        XCTAssertFalse(enabled, "没通过验证不能打开——否则用户可能把自己锁在外面")
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: AppLockService.enabledKey))
        XCTAssertEqual(evaluator.evaluateCount, 1)
    }

    func testDisableDoesNotVerifyAndPersistsOff() async {
        let (service, evaluator, defaults) = makeSUT(enabled: true)

        service.disable()

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: AppLockService.enabledKey))
        XCTAssertEqual(evaluator.evaluateCount, 0, "关闭不需要验证：能看到开关的人已经进来了")
    }

    func testEnabledStateSurvivesRecreation() async {
        let defaults = makeDefaults()
        let first = AppLockService(evaluator: FakeBiometricEvaluator(), defaults: defaults)
        await first.enable()

        let second = AppLockService(evaluator: FakeBiometricEvaluator(), defaults: defaults)

        XCTAssertTrue(second.isEnabled, "开关状态要落 UserDefaults，重启后仍然有效")
    }

    // MARK: - 解锁

    func testUnlockSucceedsThenClearsLock() async {
        let (service, evaluator, _) = makeSUT(nextResult: true)
        await service.enable()
        service.noteBackgrounded(at: base)
        _ = service.noteActivated(at: base.addingTimeInterval(60))
        XCTAssertTrue(service.isLocked)

        let unlocked = await service.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertFalse(service.isLocked)
        XCTAssertEqual(evaluator.evaluateCount, 2, "开启一次 + 解锁一次")
    }

    func testUnlockKeepsLockedWhenVerificationFails() async {
        let (service, evaluator, _) = makeSUT(nextResult: true)
        await service.enable()
        service.noteBackgrounded(at: base)
        _ = service.noteActivated(at: base.addingTimeInterval(60))

        evaluator.nextResult = false
        let unlocked = await service.unlock()

        XCTAssertFalse(unlocked)
        XCTAssertTrue(service.isLocked, "验证失败必须保持锁定")
    }

    func testUnlockWhenNotLockedIsNoOp() async {
        let (service, evaluator, _) = makeSUT(enabled: true)

        let unlocked = await service.unlock()

        XCTAssertTrue(unlocked)
        XCTAssertEqual(evaluator.evaluateCount, 0, "没锁就不该弹验证")
    }
}
