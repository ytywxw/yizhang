//
//  SubscriptionEditorViewModelTests.swift
//  一账Tests / Services
//
//  T13 的五条验收（对应 `SubscriptionEditorViewModel` 的设计注释）：
//  ① 名称为空不能保存（并且真的什么都不写）；
//  ② 首次扣费日晚于下次扣费日不能保存；
//  ③ 试用中把「下次扣费日」换成「试用结束日」，且**不给补录选项**；
//  ④ 首次扣费日在过去 → 返回 `BackfillOption`，默认不补（只提示）；
//  ⑤ 保存后**立刻扫一次**（E-10：日期改到过去要马上看到账）。
//
//  另外两条容易回归的点：
//  ⑥ 手改「下次扣费日」才算校正（`didOverrideNextBilling`），没改就不该传，
//     否则每次编辑都会重置锚定日（R-SUB-8）；
//  ⑦ 周期档位与「每 N 天/每 N 个月」的互转。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class SubscriptionEditorViewModelTests: XCTestCase {

    /// 固定"今天"：2026-11-21。
    private let today = DateOnly(key: 20261121)

    // MARK: - ① 名称为空

    func testSaveRejectsEmptyNameAndWritesNothing() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.amountText = "25"
        XCTAssertFalse(viewModel.canSave)
        XCTAssertEqual(viewModel.saveDisabledReason, "请填写订阅名称")

        XCTAssertNil(viewModel.save(), "名称为空必须保存失败")
        XCTAssertEqual(viewModel.errorMessage, "请填写订阅名称")
        XCTAssertEqual(try sut.subscriptionCount(), 0, "校验失败不能留下半条数据")
        XCTAssertEqual(try sut.entryCount(), 0)
    }

    func testSaveRejectsWhitespaceOnlyNameAndOverlongName() throws {
        let sut = try makeSUT()

        let blank = sut.editor(mode: .create, today: today)
        blank.name = "   \n "
        blank.amountText = "25"
        XCTAssertNil(blank.save())

        let long = sut.editor(mode: .create, today: today)
        long.name = String(repeating: "长", count: SubscriptionEditorViewModel.nameLimit + 1)
        long.amountText = "25"
        XCTAssertFalse(long.canSave)
        XCTAssertEqual(long.saveDisabledReason, "名称最多 30 个字")
        XCTAssertNil(long.save())
    }

    // MARK: - ② 日期顺序

    func testSaveRejectsFirstBillingLaterThanNextBilling() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "视频会员"
        viewModel.amountText = "25"

        viewModel.select(firstBillingDay: today.adding(days: 10))
        viewModel.select(nextBillingDay: today)

        XCTAssertFalse(viewModel.canSave)
        XCTAssertEqual(viewModel.saveDisabledReason, "首次扣费日不能晚于下次扣费日")
        XCTAssertNil(viewModel.save())
        XCTAssertEqual(try sut.subscriptionCount(), 0, "日期顺序不合法时一笔都不能写")
    }

    // MARK: - ③ 试用

    func testTrialReplacesNextBillingDayAndHidesBackfill() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "云盘"
        viewModel.amountText = "120"
        // 首次扣费日放在过去：如果没有试用，这里一定会弹补录
        viewModel.select(firstBillingDay: today.adding(months: -3))
        viewModel.setTrialEnabled(true)
        viewModel.trialEndDay = today.adding(days: 14)

        XCTAssertTrue(viewModel.isInTrial)
        XCTAssertEqual(
            viewModel.effectiveNextBillingDay, today.adding(days: 14),
            "试用中「下次扣费日」显示的是试用结束日（E-1）"
        )

        let result = try XCTUnwrap(viewModel.save())

        XCTAssertNil(result.backfill, "试用中不给补录：否则会把「试用」补成「已付费」")
        XCTAssertFalse(result.needsBackfillDecision)
        let created = try XCTUnwrap(sut.storedSubscription(id: result.subscriptionID))
        XCTAssertEqual(created.trialEndDay, today.adding(days: 14).key)
        XCTAssertEqual(created.nextBillingDay, today.adding(days: 14).key)
        XCTAssertEqual(try sut.entryCount(), 0, "试用期内不该生成账目")
    }

    func testExpiredTrialBehavesLikeNormalSubscription() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "过期的试用"
        viewModel.amountText = "0"
        viewModel.setTrialEnabled(true)
        viewModel.trialEndDay = today.adding(days: -1)

        XCTAssertFalse(viewModel.isInTrial, "试用结束日已过 = 不在试用中")
        XCTAssertEqual(viewModel.effectiveNextBillingDay, viewModel.nextBillingDay)
    }

    // MARK: - ④ 补录选项

    func testPastFirstBillingOffersBackfillButDoesNotBackfillByDefault() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "视频会员"
        viewModel.amountText = "25"
        // 10 天前 = 11/11，只有一个已过去的周期（12/11 还没到），断言可以写死
        let pastDay = today.adding(days: -10)
        viewModel.select(firstBillingDay: pastDay)

        let result = try XCTUnwrap(viewModel.save())

        let option = try XCTUnwrap(result.backfill, "首次扣费日在过去要弹补录询问")
        XCTAssertTrue(result.needsBackfillDecision)
        XCTAssertEqual(option.availableCycles, 1)
        XCTAssertEqual(option.latestDay, pastDay)
        XCTAssertEqual(
            BackfillOption.defaultCycles, 0,
            "E-5：默认不补，补账会污染历史统计"
        )
        XCTAssertEqual(
            try sut.entryCount(), 1,
            "只有当期那一笔（由保存后的扫描生成），补录一笔都没执行"
        )
    }

    func testFutureFirstBillingOffersNoBackfill() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "下个月的会员"
        viewModel.amountText = "25"
        viewModel.select(firstBillingDay: today.adding(days: 10))

        let result = try XCTUnwrap(viewModel.save())

        XCTAssertNil(result.backfill, "没有已过去的周期就没有可补的东西")
        XCTAssertFalse(result.needsBackfillDecision)
        XCTAssertEqual(result.sweepGeneratedCount, 0)
    }

    // MARK: - ⑤ 保存后立刻扫一次（E-10）

    func testSaveRunsSweepImmediatelySoPastBillingAppearsAtOnce() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "视频会员"
        viewModel.amountText = "25"
        let pastDay = today.adding(days: -10)
        viewModel.select(firstBillingDay: pastDay)

        XCTAssertEqual(try sut.entryCount(), 0, "保存前库里没有账目")

        let result = try XCTUnwrap(viewModel.save())

        XCTAssertEqual(
            result.sweepGeneratedCount, 1,
            "保存里必须扫一次（force: true），否则用户要等下次冷启动才看到账"
        )
        let entries = try sut.liveEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.occurredDay, pastDay.key)
        XCTAssertEqual(entries.first?.source, .subscription)
        XCTAssertEqual(entries.first?.amount, 2500)
    }

    // MARK: - ⑥ 只有手改才算校正

    func testEditingWithoutTouchingNextBillingKeepsAnchorStable() throws {
        let sut = try makeSUT()
        // 造一条 1/31 建、锚定 31 的订阅（最容易漂的一类）
        let created = try sut.environment.subscription.create(
            SubscriptionDraft(name: "月末订阅", amount: 1000, firstBillingDay: 20260131),
            today: today
        )
        _ = sut.environment.sweep.sweep(today: today, force: true)
        let before = try XCTUnwrap(sut.storedSubscription(id: created.subscriptionID))
        let anchorBefore = before.billingAnchorDay
        let nextBefore = before.nextBillingDay

        let viewModel = sut.editor(mode: .edit(created.subscriptionID), today: today)
        viewModel.name = "月末订阅（改名）"
        XCTAssertFalse(
            viewModel.didOverrideNextBilling,
            "回填不能把手改标记置上，否则每次改名都会重置锚定日（R-SUB-8）"
        )

        let result = try XCTUnwrap(viewModel.save())

        let after = try XCTUnwrap(sut.storedSubscription(id: result.subscriptionID))
        XCTAssertEqual(after.name, "月末订阅（改名）")
        XCTAssertEqual(
            after.billingAnchorDay, anchorBefore,
            "锚定日不能被「顺手改个名字」重置（R-SUB-8）"
        )
        XCTAssertEqual(after.nextBillingDay, nextBefore)
        XCTAssertEqual(try sut.entryCount(), 10, "1/31…10/31 共 10 期历史账目不受影响")
    }

    func testManuallyChangingNextBillingMarksOverride() throws {
        let sut = try makeSUT()
        let created = try sut.environment.subscription.create(
            // 首次扣费日必须在过去：否则「把下次扣费日改到近期」会违反"首次 ≤ 下次"
            SubscriptionDraft(name: "视频会员", amount: 2500, firstBillingDay: today.adding(days: -30).key),
            today: today
        )
        let viewModel = sut.editor(mode: .edit(created.subscriptionID), today: today)
        XCTAssertFalse(viewModel.didOverrideNextBilling)

        let corrected = today.adding(days: 3)
        viewModel.select(nextBillingDay: corrected)

        XCTAssertTrue(viewModel.didOverrideNextBilling, "UI 上要出现「以此为准」")

        let result = try XCTUnwrap(viewModel.save())
        let after = try XCTUnwrap(sut.storedSubscription(id: result.subscriptionID))
        XCTAssertEqual(after.nextBillingDay, corrected.key)
        XCTAssertEqual(after.billingAnchorDay, corrected.day, "手改下次扣费日 → 锚定日由服务层重置（E-10）")
    }

    // MARK: - ⑦ 周期档位

    func testCyclePresetMapping() {
        XCTAssertEqual(CyclePreset.matching(unit: .week, value: 1), .weekly)
        XCTAssertEqual(CyclePreset.matching(unit: .month, value: 1), .monthly)
        XCTAssertEqual(CyclePreset.matching(unit: .quarter, value: 1), .quarterly)
        XCTAssertEqual(CyclePreset.matching(unit: .year, value: 1), .yearly)
        XCTAssertEqual(CyclePreset.matching(unit: .month, value: 2), .custom, "每 2 个月 = 自定义")
        XCTAssertEqual(CyclePreset.matching(unit: .day, value: 1), .custom, "按天没有固定档位")

        XCTAssertEqual(CyclePreset.weekly.fixedUnit, .week)
        XCTAssertNil(CyclePreset.custom.fixedUnit)
    }

    func testCustomCycleWritesUnitAndValue() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "每两个月"
        viewModel.amountText = "25"
        viewModel.select(preset: .custom)
        viewModel.select(customUnit: .month)
        viewModel.customValue = 2

        XCTAssertEqual(viewModel.resolvedCycle.unit, .month)
        XCTAssertEqual(viewModel.resolvedCycle.value, 2)

        let result = try XCTUnwrap(viewModel.save())
        let created = try XCTUnwrap(sut.storedSubscription(id: result.subscriptionID))
        XCTAssertEqual(created.cycleUnit, .month)
        XCTAssertEqual(created.cycleValue, 2)
    }

    func testCustomCycleValueIsClamped() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "越界周期"
        viewModel.amountText = "25"
        viewModel.select(preset: .custom)
        viewModel.customValue = 0

        XCTAssertEqual(viewModel.resolvedCycle.value, 1, "0 天会被夹到 1 天，而不是让服务抛错")
        XCTAssertTrue(viewModel.canSave)
    }

    // MARK: - 默认值与零金额

    func testDefaultsUseSubscriptionCategoryAndFirstAccount() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)

        XCTAssertEqual(viewModel.categoryID, PresetCatalog.subscriptionCategoryID, "新建默认「订阅服务」")
        XCTAssertNotNil(viewModel.accountID, "账户默认上次使用的（首次就是第一个）")
        XCTAssertFalse(viewModel.categories.isEmpty)
        XCTAssertFalse(viewModel.accounts.isEmpty)
    }

    func testZeroAmountIsAllowedAndExplained() throws {
        let sut = try makeSUT()
        let viewModel = sut.editor(mode: .create, today: today)
        viewModel.name = "免费试用中"
        viewModel.amountText = "0"

        XCTAssertTrue(viewModel.canSave, "E-9：0 元订阅允许保存（只提醒不记账）")
        XCTAssertEqual(viewModel.amountDisplayText, "免费（只提醒，不记账）")

        let result = try XCTUnwrap(viewModel.save())
        let created = try XCTUnwrap(sut.storedSubscription(id: result.subscriptionID))
        XCTAssertEqual(created.amount, 0)
        XCTAssertEqual(try sut.entryCount(), 0, "0 元不生成账目")
    }

    // MARK: - 编辑模式的两个危险动作是分开的

    func testCancelKeepsSubscriptionWhileDeleteRemovesIt() throws {
        let sut = try makeSUT()
        let toCancel = try sut.environment.subscription.create(
            SubscriptionDraft(name: "要取消的", amount: 1000, firstBillingDay: 20261201),
            today: today
        )
        let toDelete = try sut.environment.subscription.create(
            SubscriptionDraft(name: "要删除的", amount: 1000, firstBillingDay: 20261202),
            today: today
        )

        let cancelVM = sut.editor(mode: .edit(toCancel.subscriptionID), today: today)
        XCTAssertEqual(cancelVM.cancelSubscription(), "已取消订阅，历史账目保留")
        let cancelled = try XCTUnwrap(sut.storedSubscription(id: toCancel.subscriptionID))
        XCTAssertEqual(cancelled.status, .cancelled, "取消 = 订阅还在，只是不再扣费")
        XCTAssertEqual(try sut.subscriptionCount(), 2)

        let deleteVM = sut.editor(mode: .edit(toDelete.subscriptionID), today: today)
        XCTAssertEqual(deleteVM.deleteSubscription(), "已删除订阅")
        XCTAssertEqual(try sut.subscriptionCount(), 1, "删除 = 订阅本身没了")
        XCTAssertNil(sut.storedSubscription(id: toDelete.subscriptionID))
    }

    // MARK: - 工具

    @MainActor
    private struct SUT {
        let environment: AppEnvironment

        func editor(
            mode: SubscriptionEditorViewModel.Mode,
            today: DateOnly
        ) -> SubscriptionEditorViewModel {
            let viewModel = SubscriptionEditorViewModel(mode: mode, today: today)
            viewModel.attach(environment)
            return viewModel
        }

        func storedSubscription(id: UUID) -> Subscription? {
            try? environment.readContext.fetch(QueryDescriptors.subscription(id: id)).first
        }

        func subscriptionCount() throws -> Int {
            try environment.readContext.fetch(QueryDescriptors.allSubscriptions()).count
        }

        func entryCount() throws -> Int {
            try liveEntries().count
        }

        func liveEntries() throws -> [LedgerEntry] {
            try environment.readContext
                .fetch(QueryDescriptors.allEntries())
                .filter { $0.deletedAt == nil }
        }
    }

    private func makeSUT() throws -> SUT {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        return SUT(environment: environment)
    }
}
