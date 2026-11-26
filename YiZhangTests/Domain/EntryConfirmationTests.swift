//
//  EntryConfirmationTests.swift
//  一账Tests / Domain
//
//  职责：钉死「订阅账目要不要等用户核对」这条规则的**边界**（V1.1 F-SUB-13 / PRD 2.2）。
//
//  为什么这组测试值得单独一个文件：
//  这条规则是"一个数字 + 一个比较"，看起来 trivial，但它在 V1.1 里是**唯一**决定
//  用户看到哪几笔账要核对的地方，而且有两条完全不同的写入路径（结算扫描 / 补录）
//  都依赖它。窗口差一天 = 屏幕上多一笔或少一笔要确认的账，没有任何其它测试能发现
//  （不会崩、不会报错、金额也对）。所以这里把 8 个自然日的首尾各钉一颗钉子。
//
//  边界定义（`EntryConfirmation.forSubscription`）：应扣日 `>= 今天 - 7 天` → pending。
//  ⇒ 今天、-1 … -7 天 → pending（8 个自然日）；-8 天及更早 → confirmed。
//

import XCTest
@testable import YiZhang

final class EntryConfirmationTests: XCTestCase {

    /// 固定"今天"：2026-03-15（周日，非月末，避免被 28/30/31 的月份天数干扰）。
    private let today = DateOnly(key: 20260315)

    // MARK: - ① 窗口边界（今天 / -7 / -8）

    func testDueTodayIsPending() {
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: today.key, today: today),
            .pending,
            "今天刚扣的那笔必须等用户核对，否则「待确认」这个功能就没有入口"
        )
    }

    func testDueYesterdayIsPending() {
        let day = today.adding(days: -1)
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: day.key, today: today),
            .pending
        )
    }

    func testSevenDaysAgoIsStillPending() {
        let day = today.adding(days: -EntryConfirmation.pendingWindowDays)
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: day.key, today: today),
            .pending,
            "窗口的下边界是**闭区间**：-7 天仍在窗口内"
        )
    }

    func testEightDaysAgoIsConfirmed() {
        let day = today.adding(days: -(EntryConfirmation.pendingWindowDays + 1))
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: day.key, today: today),
            .confirmed,
            "越界一天就必须落回 confirmed——否则用户每次打开 App 都会被半年前的账目骚扰"
        )
    }

    func testWindowIsSevenDays() {
        // 这个数字不是实现细节：PRD 2.2 写死了 7 天，改动它等于改需求。
        // 钉住它是为了让"顺手改成 14 天"这种事在 CI 上就被拦下。
        XCTAssertEqual(EntryConfirmation.pendingWindowDays, 7)
    }

    // MARK: - ② 冷启动补漏：久远的历史账目不能被判成待确认（架构 R7 的反面）

    func testColdStartBackfillOfSixtyDaysAgoIsConfirmed() {
        let day = today.adding(days: -60)
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: day.key, today: today),
            .confirmed,
            "用户三个月没开 App，补漏出来的两笔都必须是已确认"
        )
    }

    // MARK: - ③ 脏输入一律降级为 confirmed（宁可不打扰，也不要凭空造出待确认）

    func testZeroOccurredDayIsConfirmed() {
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: 0, today: today),
            .confirmed,
            "occurredDay == 0 是「没有日期」的哨兵值，不是 1970 年，绝不能被当成很久以前或很久以后"
        )
    }

    func testNegativeOccurredDayIsConfirmed() {
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: -100, today: today),
            .confirmed
        )
    }

    func testInvalidTodayFallsBackToConfirmed() {
        // 设备时钟/时区极端情况下可能算出 key == 0。此时无法判定窗口，
        // 降级成 confirmed：待确认是个"提醒"，提醒失效比提醒错乱更安全。
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: today.key, today: DateOnly(key: 0)),
            .confirmed
        )
    }

    func testFutureDueDayIsPending() {
        // 理论上 `LedgerService.validateDay` 会先挡住未来日期，这里只钉死函数自身行为：
        // 未来日 >= 窗口起点，所以是 pending。写下来是为了避免有人把它"修"成 confirmed
        // 之后，某条绕过校验的路径（如扫描时时钟回拨）悄悄改变语义。
        let day = today.adding(days: 3)
        XCTAssertEqual(
            EntryConfirmation.forSubscription(occurredDay: day.key, today: today),
            .pending
        )
    }

    // MARK: - ④ raw 往返（落库 / 读取的口径必须一致）

    func testRawRoundTrip() {
        XCTAssertEqual(EntryConfirmation(raw: EntryConfirmation.pending.raw), .pending)
        XCTAssertEqual(EntryConfirmation(raw: EntryConfirmation.confirmed.raw), .confirmed)
        XCTAssertNil(EntryConfirmation(raw: "unknown"))
        XCTAssertEqual(EntryConfirmation.pending.displayName, "待确认")
        XCTAssertTrue(EntryConfirmation.pending.isPending)
        XCTAssertFalse(EntryConfirmation.confirmed.isPending)
    }
}
