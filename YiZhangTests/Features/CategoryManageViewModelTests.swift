//
//  CategoryManageViewModelTests.swift
//  一账Tests / Features
//
//  T21 分类管理里最容易出事的不是 UI，而是三条业务规则：
//  ① 预置分类**不可删**（R-CAT-1）——只能隐藏；
//  ② 删除自定义分类时，若其下有账目**必须迁移**（R-CAT-2），绝不允许留下无分类账目；
//  ③ 分类与账目类型强绑（R-CAT）：支出账目不能迁到收入分类下。
//
//  这三条一旦破了，后果是静默的：统计页会把"无分类"聚成一个灰块，
//  用户看到的是"我这个月有一大笔不知道花在哪"，而他并没有做错任何事。
//

import XCTest
import SwiftData
@testable import YiZhang

@MainActor
final class CategoryManageViewModelTests: XCTestCase {

    private func makeSUT() throws -> (environment: AppEnvironment, viewModel: CategoryManageViewModel) {
        let container = try ModelContainerFactory.make(inMemory: true)
        let environment = try AppEnvironment(container: container)
        let viewModel = CategoryManageViewModel()
        viewModel.attach(environment)
        return (environment, viewModel)
    }

    /// 造一个自定义分类 + 一笔账目，返回 (分类 id, 账目 id)。
    private func makeCustomCategoryWithEntry(
        _ environment: AppEnvironment,
        _ viewModel: CategoryManageViewModel,
        name: String = "咖啡",
        amount: Int64 = 2800
    ) throws -> (categoryID: UUID, entryID: UUID) {
        let categoryID = try viewModel.create(
            name: name,
            type: .expense,
            iconName: "cup.and.saucer",
            colorHex: "#6D4C41"
        )
        let accounts = try environment.writer.fetch(QueryDescriptors.accounts())
        let accountID = try XCTUnwrap(accounts.first?.id)

        var draft = EntryDraft(amount: amount, occurredDay: 20261120)
        draft.categoryID = categoryID
        draft.accountID = accountID
        let outcome = try environment.ledger.create(draft)
        let entryID = try XCTUnwrap(outcome.entryID)
        viewModel.load()
        return (categoryID, entryID)
    }

    // MARK: - 预置分类不可删

    func testPresetCategoryCannotBeDeleted() throws {
        let (_, viewModel) = try makeSUT()
        let preset = try XCTUnwrap(viewModel.expenseRows.first { $0.isPreset })

        let preview = try XCTUnwrap(viewModel.deletePreview(for: preset.id))
        XCTAssertEqual(preview, .notAllowed(name: preset.name))
        XCTAssertFalse(preview.canProceed)
        XCTAssertTrue(preview.message.contains("预置分类"))

        XCTAssertThrowsError(try viewModel.delete(id: preset.id)) { error in
            XCTAssertEqual(error as? CategoryManageError, .presetNotDeletable)
        }
        XCTAssertTrue(viewModel.rows(for: .expense).contains { $0.id == preset.id }, "预置分类必须还在")
    }

    func testPresetCategoryRowExplainsWhyDeleteIsUnavailable() throws {
        let (_, viewModel) = try makeSUT()
        let preset = try XCTUnwrap(viewModel.expenseRows.first { $0.isPreset })

        XCTAssertFalse(preset.canDelete)
        XCTAssertEqual(preset.deleteHint, "预置分类不可删除，可隐藏")
    }

    // MARK: - 删除必须迁移

    func testDeletingCategoryWithEntriesRequiresMigrationTarget() throws {
        let (environment, viewModel) = try makeSUT()
        let (categoryID, _) = try makeCustomCategoryWithEntry(environment, viewModel)

        let preview = try XCTUnwrap(viewModel.deletePreview(for: categoryID))
        guard case .requiresMigration(_, let count) = preview else {
            return XCTFail("有账目的分类必须要求迁移，实际是 \(preview)")
        }
        XCTAssertEqual(count, 1)

        XCTAssertThrowsError(try viewModel.delete(id: categoryID)) { error in
            XCTAssertEqual(error as? CategoryManageError, .migrationTargetRequired)
        }
        XCTAssertTrue(
            viewModel.rows(for: .expense).contains { $0.id == categoryID },
            "没给迁移目标时不能半途删掉分类"
        )
    }

    func testDeletingCategoryMigratesEntriesToTarget() throws {
        let (environment, viewModel) = try makeSUT()
        let (categoryID, entryID) = try makeCustomCategoryWithEntry(environment, viewModel)
        let target = try XCTUnwrap(
            viewModel.expenseRows.first { $0.isPreset && $0.id != categoryID }
        )

        let outcome = try viewModel.delete(id: categoryID, migratingTo: target.id)

        XCTAssertEqual(outcome, .migrated(entryCount: 1))

        // 账目必须挂到目标分类上（而不是变成无分类）
        let entries = try environment.writer.fetch(QueryDescriptors.allEntries())
        let migrated = try XCTUnwrap(entries.first { $0.id == entryID })
        XCTAssertEqual(migrated.category?.id, target.id, "迁移后账目的分类必须是目标分类")
        XCTAssertNotNil(migrated.category, "R-CAT-2：绝不允许留下无分类账目")

        // 分类本身没了
        XCTAssertFalse(viewModel.rows(for: .expense).contains { $0.id == categoryID })
        let categories = try environment.writer.fetch(QueryDescriptors.categories(of: .expense))
        XCTAssertFalse(categories.contains { $0.id == categoryID })
    }

    func testDeletingCategoryWithoutEntriesDeletesDirectly() throws {
        let (_, viewModel) = try makeSUT()
        let categoryID = try viewModel.create(
            name: "空分类",
            type: .expense,
            iconName: "circle",
            colorHex: "#5F6368"
        )

        let preview = try XCTUnwrap(viewModel.deletePreview(for: categoryID))
        XCTAssertEqual(preview, .direct(name: "空分类"))

        XCTAssertEqual(try viewModel.delete(id: categoryID), .deleted)
        XCTAssertFalse(viewModel.rows(for: .expense).contains { $0.id == categoryID })
    }

    func testMigrationRejectsCrossTypeTarget() throws {
        let (environment, viewModel) = try makeSUT()
        let (categoryID, _) = try makeCustomCategoryWithEntry(environment, viewModel)
        let incomeTarget = try XCTUnwrap(viewModel.incomeRows.first)

        XCTAssertThrowsError(
            try viewModel.delete(id: categoryID, migratingTo: incomeTarget.id)
        ) { error in
            XCTAssertEqual(error as? CategoryManageError, .migrationTypeMismatch)
        }
    }

    func testMigrationRejectsSelfTarget() throws {
        let (environment, viewModel) = try makeSUT()
        let (categoryID, _) = try makeCustomCategoryWithEntry(environment, viewModel)

        XCTAssertThrowsError(
            try viewModel.delete(id: categoryID, migratingTo: categoryID)
        ) { error in
            XCTAssertEqual(error as? CategoryManageError, .migrationTargetIsSelf)
        }
    }

    // MARK: - 隐藏

    func testHiddenCategoryLeavesEntryPickerButKeepsRow() throws {
        let (_, viewModel) = try makeSUT()
        let categoryID = try viewModel.create(
            name: "外卖",
            type: .expense,
            iconName: "bag",
            colorHex: "#B26A00"
        )

        try viewModel.setHidden(true, for: categoryID)

        XCTAssertTrue(viewModel.rows(for: .expense).contains { $0.id == categoryID }, "管理页还要看得到")
        XCTAssertFalse(
            viewModel.selectableRows(for: .expense).contains { $0.id == categoryID },
            "记账页选择器不能再出现隐藏分类"
        )

        try viewModel.setHidden(false, for: categoryID)
        XCTAssertTrue(viewModel.selectableRows(for: .expense).contains { $0.id == categoryID })
    }

    func testHiddenPresetCategoryStillCannotBeDeleted() throws {
        let (_, viewModel) = try makeSUT()
        let preset = try XCTUnwrap(viewModel.expenseRows.first { $0.isPreset })

        try viewModel.setHidden(true, for: preset.id)

        XCTAssertThrowsError(try viewModel.delete(id: preset.id)) { error in
            XCTAssertEqual(error as? CategoryManageError, .presetNotDeletable)
        }
    }

    // MARK: - 新建 / 编辑

    func testCreateRejectsEmptyAndDuplicateName() throws {
        let (_, viewModel) = try makeSUT()

        XCTAssertThrowsError(
            try viewModel.create(name: "  ", type: .expense, iconName: "circle", colorHex: "#5F6368")
        ) { error in
            XCTAssertEqual(error as? CategoryManageError, .emptyName)
        }

        let existing = try XCTUnwrap(viewModel.expenseRows.first)
        XCTAssertThrowsError(
            try viewModel.create(
                name: existing.name,
                type: .expense,
                iconName: "circle",
                colorHex: "#5F6368"
            )
        ) { error in
            XCTAssertEqual(error as? CategoryManageError, .duplicateName(existing.name))
        }
    }

    func testNewCategoryAppearsInItsOwnTypeOnly() throws {
        let (_, viewModel) = try makeSUT()
        let id = try viewModel.create(
            name: "副业收入",
            type: .income,
            iconName: "yensign.circle",
            colorHex: "#2E7D32"
        )

        XCTAssertTrue(viewModel.incomeRows.contains { $0.id == id })
        XCTAssertFalse(viewModel.expenseRows.contains { $0.id == id }, "收入分类不能出现在支出 Tab")
    }

    func testUpdateChangesNameIconAndColor() throws {
        let (_, viewModel) = try makeSUT()
        let id = try viewModel.create(
            name: "咖啡",
            type: .expense,
            iconName: "cup.and.saucer",
            colorHex: "#6D4C41"
        )

        let replacementIcon = try XCTUnwrap(PresetCatalog.symbolNames.first { $0 != "cup.and.saucer" })
        try viewModel.update(id: id, name: "咖啡因", iconName: replacementIcon, colorHex: "#C0392B")

        let row = try XCTUnwrap(viewModel.expenseRows.first { $0.id == id })
        XCTAssertEqual(row.name, "咖啡因")
        XCTAssertEqual(row.iconName, replacementIcon)
        XCTAssertEqual(row.colorHex, "#C0392B")
    }

    func testUnknownIconFallsBackToWhitelist() throws {
        let (_, viewModel) = try makeSUT()
        let id = try viewModel.create(
            name: "奇怪图标",
            type: .expense,
            iconName: "这不是一个 SF Symbol",
            colorHex: "#5F6368"
        )

        let row = try XCTUnwrap(viewModel.expenseRows.first { $0.id == id })
        XCTAssertTrue(
            PresetCatalog.symbolNames.contains(row.iconName),
            "图标必须落在 40 个白名单里，否则会渲染成空白方块"
        )
    }

    // MARK: - 排序

    func testMoveReordersWithinTypeAndKeepsContiguousSortOrder() throws {
        let (_, viewModel) = try makeSUT()
        let id = try viewModel.create(
            name: "置顶分类",
            type: .expense,
            iconName: "star",
            colorHex: "#8A6D00"
        )

        try viewModel.move(id: id, toIndex: 0, type: .expense)

        XCTAssertEqual(viewModel.expenseRows.first?.id, id)
        XCTAssertEqual(viewModel.expenseRows.map(\.sortOrder), Array(0..<viewModel.expenseRows.count))
        XCTAssertTrue(
            viewModel.incomeRows.allSatisfy { $0.type == .income },
            "排序不能把收入分类混进支出序列"
        )
    }

    func testMigrationTargetsExcludeSelfAndKeepSameType() throws {
        let (_, viewModel) = try makeSUT()
        let id = try viewModel.create(
            name: "咖啡",
            type: .expense,
            iconName: "cup.and.saucer",
            colorHex: "#6D4C41"
        )

        let targets = viewModel.migrationTargets(for: id, type: .expense)

        XCTAssertFalse(targets.contains { $0.id == id })
        XCTAssertTrue(targets.allSatisfy { $0.type == .expense })
        XCTAssertEqual(targets.count, viewModel.expenseRows.count - 1)
    }
}
