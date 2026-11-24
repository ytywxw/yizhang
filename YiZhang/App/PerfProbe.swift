//
//  PerfProbe.swift
//  YiZhang / App
//
//  职责：开发期性能探针（T24）——**冷启动**与**滚动帧率**的实测数据。
//
//  整个文件包在 `#if DEBUG` 里：Release 二进制中不存在这个类型，
//  也没有任何 `YIZHANG_MEASURE_*` 的读取代码（与 `DebugDemoData` 同一套隔离策略）。
//
//  ## 为什么冷启动要在 App 自己的第一行代码里打点
//
//  `CFAbsoluteTimeGetCurrent()` 在 `YiZhangApp.init()` 的第一行取，取到的是
//  "App 代码开始执行"的时刻；把"首帧提交后的一轮 runloop"当终点。
//  这样测到的是 **App 自己能控制的那一段**（建容器、装配服务、首帧渲染）。
//  dyld / 进程加载那一段这个探针测不到，所以报告里会同时给 `simctl launch`
//  的墙钟时间做上界——两个数字一起看才是诚实的。
//
//  ## 为什么滚动帧率要程序化驱动
//
//  模拟器里没有脚本化的手指滑动，`simctl` 也没有 "swipe" 命令。
//  但帧率测的是"主线程每帧能不能在 16.7ms 内交差"，所以用
//  `ScrollViewProxy.scrollTo` + 逐段 linear 动画把列表真实地滚起来，
//  再用 `CADisplayLink` 采样帧间隔，测到的就是同一件事：
//  这台机器渲染这个列表时会不会掉帧。
//

#if DEBUG

import SwiftUI
import QuartzCore

// MARK: - 探针

/// 开发期性能探针。所有方法在没传对应启动参数时都是空操作。
@MainActor
enum PerfProbe {

    /// `-YIZHANG_MEASURE_LAUNCH 1`：打印冷启动到可交互的耗时。
    static let launchKey = "YIZHANG_MEASURE_LAUNCH"

    /// `-YIZHANG_MEASURE_FPS 1`：自动滚动首页列表并打印帧率统计。
    static let fpsKey = "YIZHANG_MEASURE_FPS"

    private static var startedAt = CFAbsoluteTimeGetCurrent()
    private static var didReportLaunch = false
    private static var didReportFPS = false

    /// 把一行探针数据同时写进 stdout 与 `Documents/yizhang-perf.log`。
    ///
    /// 只 `print` 是不够的：`simctl launch --console-pty` 在 CI / 脚本里抓不到
    /// App 的 stdout（实测只回一行 pid），数据就丢了。写文件后
    /// `xcrun simctl get_app_container booted com.xiaoban.yizhang data` 一定读得到。
    static func record(_ line: String) {
        print(line)
        let url = URL.documentsDirectory.appendingPathComponent("yizhang-perf.log")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 冷启动

    /// 在 `YiZhangApp.init()` 的第一行调用。
    static func markAppStart() {
        startedAt = CFAbsoluteTimeGetCurrent()
    }

    /// 首帧提交后调用一次（`RootTabView` 的 `.task`）。
    static func markFirstFrameIfRequested() {
        guard UserDefaults.standard.bool(forKey: launchKey), !didReportLaunch else { return }
        didReportLaunch = true
        let milliseconds = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        record(String(format: "[PERF] launch→interactive: %.0fms", milliseconds))
    }

    // MARK: 滚动帧率

    /// 程序化滚动首页列表，采样帧间隔并打印统计。
    ///
    /// - Parameters:
    ///   - proxy: 首页的 `ScrollViewProxy`。
    ///   - groupIDs: 依次要滚到的分组锚点（`DayGroup.ID`）。
    static func driveScrollIfRequested(proxy: ScrollViewProxy, groupIDs: [AnyHashable]) async {
        guard UserDefaults.standard.bool(forKey: fpsKey), !didReportFPS else { return }
        guard groupIDs.count >= 3 else {
            record("[PERF] fps: 分组不足（\(groupIDs.count) 个），跳过滚动采样")
            return
        }
        didReportFPS = true

        // 等首帧稳定再开始，否则测到的是启动尾部的抖动
        try? await Task.sleep(nanoseconds: 700_000_000)

        let meter = FrameRateMeter()
        meter.start()

        // 锚点抽样：1 万条账目可能横跨几百个分组，逐段滚动会跑好几分钟。
        // 均匀取最多 25 个锚点，往下滚一遍再滚回来——覆盖"新建行进入视窗"与"复用"两种路径。
        let stride = max(1, groupIDs.count / 25)
        let forward = groupIDs.enumerated()
            .filter { $0.offset % stride == 0 }
            .map { $0.element }
        let backward = forward.reversed().map { $0 }
        for anchor in forward + backward {
            withAnimation(.linear(duration: 0.2)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // 让最后一段动画跑完
        try? await Task.sleep(nanoseconds: 300_000_000)
        record(meter.stop())
    }
}

// MARK: - 帧率计

/// 用 `CADisplayLink` 采样真实帧间隔。
///
/// 判据不是"平均 fps"——平均 58 也可能是一秒掉到 30 又补回来。
/// 所以这里同时给 **p95 帧间隔** 与 **掉帧数**（间隔 > 1.5 个刷新周期）。
@MainActor
final class FrameRateMeter: NSObject {

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var startedAt: CFAbsoluteTime = 0

    func start() {
        guard link == nil else { return }
        startedAt = CFAbsoluteTimeGetCurrent()
        lastTimestamp = 0
        intervals.removeAll(keepingCapacity: true)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc
    private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let interval = (link.timestamp - lastTimestamp) * 1000
        // 首帧与切后台上会给出异常值，直接丢掉
        guard interval > 0, interval < 250 else { return }
        intervals.append(interval)
    }

    /// 停止采样并返回一行统计。
    func stop() -> String {
        link?.invalidate()
        link = nil

        let duration = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        guard !intervals.isEmpty else {
            return "[PERF] fps: 没有采到帧（采样 \(String(format: "%.0f", duration))ms）"
        }

        let sorted = intervals.sorted()
        let count = sorted.count
        let average = intervals.reduce(0, +) / Double(count)
        let p50 = sorted[Int(Double(count) * 0.50)]
        let p95 = sorted[min(count - 1, Int(Double(count) * 0.95))]
        let worst = sorted[count - 1]

        // 掉帧：间隔超过 1.5 个 16.7ms 周期（即肉眼能看出的一次卡顿）
        let droppedThreshold = 16.7 * 1.5
        let dropped = intervals.filter { $0 > droppedThreshold }.count
        let droppedRatio = Double(dropped) / Double(count) * 100

        return String(
            format: "[PERF] fps: %d 帧 / %.0fms，平均 %.1ffps，帧间隔 p50 %.1fms / p95 %.1fms / 最差 %.1fms，掉帧 %d 帧（%.1f%%）",
            count,
            duration,
            1000.0 / average,
            p50,
            p95,
            worst,
            dropped,
            droppedRatio
        )
    }
}

#endif
