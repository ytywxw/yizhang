//
//  EntryFilterTests.swift
//  一账Tests / Domain
//
//  验证 T09 的六维筛选。之所以能把这件事测得这么细，是因为 `EntryFilter` 只依赖
//  `EntryFilterTarget` 这个纯 Swift 协议——**一次数据库都不用起**，每个维度两行就覆盖了。
//
//  六条断言对应 PRD 里六个筛选入口，另外三条是组合语义：
//  ① 维度之间是 AND、维度内部多选是 OR；
//  ② 空集合 = 不限（不是"全都不匹配"，这是筛选控件最容易搞反的地方）；
//  ③ 清除全部之后必须回到"不限"，且 `isActive` 归 false。
//

import XCTest
@testable import YiZhang

final class EntryFilterTests: XCTestCase {

    /// 固定的"今天"：2026-11-21 是周六，本周 = 11/16（周一）– 11/22。
    private let today = DateOnly(key: 20261121)

    private let food = UUID()
    private let transport = UUID()
    private let wechat = UUID()
    private let alipay = UUID()

    // MARK: - ① 时间

    func testTimeDimension() {
        let todayEntry = sample(day: 20261121)
        let thisWeekEntry = sample(day: 20261117)
        let lastWeekEntry = sample(day: 20261110)
        let items = [todayEntry, thisWeekEntry, lastWeekEntry]

        var filter = EntryFilter()
        filter.time = .today
        XCTAssertEqual(filter.apply(items, today: today).map(\.occurredDay), [20261121])

        filter.time = .week
        XCTAssertEqual(filter.apply(items, today: today).map(\.occurredDay), [20261121, 20261117])

        filter.time = .monthToDate
        XCTAssertEqual(filter.apply(items, today: today).count, 3, "本月 1 日 → 今天，三条都在")

        filter.time = .all
        XCTAssertEqual(filter.apply(items, today: today).count, 3, "不限时不过滤")
    }

    func testCustomRangeNeedsBothBounds() {
        let items = [sample(day: 20261101), sample(day: 20261110), sample(day: 20261120)]

        var filter = EntryFilter()
        filter.time = .custom
        XCTAssertEqual(filter.apply(items, today: today).count, 3, "区间没设全 → 视为不限（不能筛掉全部）")

        filter.customStartDay = 20261105
        filter.customEndDay = 20261115
        XCTAssertEqual(filter.apply(items, today: today).map(\.occurredDay), [20261110])
    }

    // MARK: - ② 类型

    func testTypeDimension() {
        let expense = sample(day: 20261120, type: .expense)
        let income = sample(day: 20261120, type: .income)
        let transfer = sample(day: 20261120, type: .transfer)
        let items = [expense, income, transfer]

        var filter = EntryFilter()
        filter.types = [.expense]
        XCTAssertEqual(filter.apply(items, today: today).count, 1)

        filter.types = [.expense, .income]
        XCTAssertEqual(filter.apply(items, today: today).count, 2, "同一维度多选是 OR")
    }

    // MARK: - ③ 分类

    func testCategoryDimension() {
        let foodEntry = sample(day: 20261120, categoryID: food)
        let transportEntry = sample(day: 20261120, categoryID: transport)
        let transferEntry = sample(day: 20261120, type: .transfer, categoryID: nil)
        let items = [foodEntry, transportEntry, transferEntry]

        var filter = EntryFilter()
        filter.categoryIDs = [food]
        XCTAssertEqual(filter.apply(items, today: today).map(\.categoryID), [food])

        filter.categoryIDs = [food, transport]
        XCTAssertEqual(filter.apply(items, today: today).count, 2)

        filter.categoryIDs = [food]
        XCTAssertFalse(
            filter.apply(items, today: today).contains { $0.type == .transfer },
            "转账没有分类，选任何分类都筛不到它"
        )
    }

    // MARK: - ④ 账户

    func testAccountDimensionMatchesBothSidesOfTransfer() {
        let wechatEntry = sample(day: 20261120, accountIDs: [wechat])
        let transferEntry = sample(day: 20261120, type: .transfer, accountIDs: [alipay, wechat])
        let otherEntry = sample(day: 20261120, accountIDs: [UUID()])
        let items = [wechatEntry, transferEntry, otherEntry]

        var filter = EntryFilter()
        filter.accountIDs = [wechat]
        XCTAssertEqual(
            filter.apply(items, today: today).count,
            2,
            "转账两侧都算：从支付宝转到微信，按微信筛也应该命中"
        )

        filter.accountIDs = [alipay]
        XCTAssertEqual(
            filter.apply(items, today: today).map(\.id),
            [transferEntry.id],
            "按转出账户筛也能命中"
        )
    }

    // MARK: - ⑤ 来源

    func testSourceDimensionDistinguishesManualTodoAndSubscription() {
        let manual = sample(day: 20261120, source: .manual)
        let todo = sample(day: 20261120, source: .todo)
        let subscription = sample(day: 20261120, source: .subscription)
        let items = [manual, todo, subscription]

        var filter = EntryFilter()
        filter.sources = [.manual]
        XCTAssertEqual(filter.apply(items, today: today).map(\.source), [.manual])

        filter.sources = [.todo]
        XCTAssertEqual(filter.apply(items, today: today).map(\.source), [.todo])

        filter.sources = [.subscription]
        XCTAssertEqual(filter.apply(items, today: today).map(\.source), [.subscription])

        filter.sources = []
        XCTAssertEqual(filter.apply(items, today: today).count, 3, "空 = 不限")
    }

    // MARK: - ⑥ 关键词

    func testKeywordDimensionIgnoresCaseAndWhitespace() {
        let lunch = sample(day: 20261120, note: "午饭 Lunch")
        let subway = sample(day: 20261120, note: "地铁")
        let items = [lunch, subway]

        var filter = EntryFilter()
        filter.keyword = "lunch"
        XCTAssertEqual(filter.apply(items, today: today).map(\.id), [lunch.id])

        filter.keyword = "  地铁  "
        XCTAssertEqual(
            filter.apply(items, today: today).map(\.id),
            [subway.id],
            "关键词要去空白后再匹配"
        )

        filter.keyword = "   "
        XCTAssertEqual(filter.apply(items, today: today).count, 2, "只有空白 → 视为没填")
    }

    // MARK: - 组合

    func testDimensionsCombineWithAnd() {
        let target = sample(day: 20261120, type: .expense, categoryID: food, accountIDs: [wechat], note: "午饭")
        let wrongCategory = sample(day: 20261120, type: .expense, categoryID: transport, accountIDs: [wechat], note: "午饭")
        let wrongAccount = sample(day: 20261120, type: .expense, categoryID: food, accountIDs: [alipay], note: "午饭")
        let wrongDay = sample(day: 20261110, type: .expense, categoryID: food, accountIDs: [wechat], note: "午饭")
        let items = [target, wrongCategory, wrongAccount, wrongDay]

        var filter = EntryFilter()
        filter.time = .week
        filter.types = [.expense]
        filter.categoryIDs = [food]
        filter.accountIDs = [wechat]
        filter.sources = [.manual]
        filter.keyword = "午饭"

        XCTAssertEqual(filter.apply(items, today: today).map(\.id), [target.id])
        XCTAssertEqual(filter.activeDimensionCount, 6)
    }

    func testEmptyFilterReturnsEverythingAndIsInactive() {
        let items = [sample(day: 20261120), sample(day: 20260101)]
        let filter = EntryFilter()

        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.apply(items, today: today).count, 2)
        XCTAssertTrue(filter.chips().isEmpty)
    }

    // MARK: - chips

    func testChipsDescribeEveryActiveDimensionAndCanBeRemovedOneByOne() {
        let categoryName = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID()
        var filter = EntryFilter()
        filter.time = .today
        filter.types = [.expense]
        filter.categoryIDs = [categoryName]
        filter.sources = [.subscription]
        filter.keyword = "午饭"

        let chips = filter.chips(categoryNames: [categoryName: "餐饮"], accountNames: [:])
        XCTAssertEqual(chips.count, 5)
        XCTAssertEqual(chips.map(\.title), ["今天", "支出", "餐饮", "订阅记账", "“午饭”"])

        // 逐个移除
        for chip in chips {
            filter.removeChip(id: chip.id)
        }
        XCTAssertFalse(filter.isActive, "全部移除后回到未筛选状态")
    }

    func testClearAllResetsEverything() {
        var filter = EntryFilter()
        filter.time = .custom
        filter.customStartDay = 20261101
        filter.customEndDay = 20261110
        filter.types = [.income]
        filter.categoryIDs = [food]
        filter.accountIDs = [wechat]
        filter.sources = [.todo]
        filter.keyword = "房租"

        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.activeDimensionCount, 6)

        filter.clearAll()

        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter, EntryFilter())
        XCTAssertEqual(filter.customStartDay, 0)
        XCTAssertEqual(filter.customEndDay, 0)
        XCTAssertTrue(filter.keyword.isEmpty)
    }

    // MARK: - 夹具

    /// 一个最小的可筛选对象（Domain 层纯值类型，不需要 ModelContainer）。
    private struct Sample: EntryFilterTarget {
        let id: UUID
        var type: EntryType = .expense
        var source: EntrySource = .manual
        var occurredDay: Int32
        var categoryID: UUID?
        var accountIDs: Set<UUID> = []
        var note: String = ""
    }

    private func sample(
        day: Int32,
        type: EntryType = .expense,
        source: EntrySource = .manual,
        categoryID: UUID? = nil,
        accountIDs: Set<UUID> = [],
        note: String = ""
    ) -> Sample {
        Sample(
            id: UUID(),
            type: type,
            source: source,
            occurredDay: day,
            categoryID: categoryID,
            accountIDs: accountIDs,
            note: note
        )
    }
}
