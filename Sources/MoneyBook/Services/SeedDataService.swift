import Foundation
import SwiftData

/// 首次启动写入的默认账户与分类，以及清空数据。
@MainActor
enum SeedDataService {
    struct CategorySeed {
        let name: String
        let symbolName: String
        let colorHex: String
    }

    static let expenseCategories: [CategorySeed] = [
        CategorySeed(name: "红包", symbolName: "gift.fill", colorHex: "#FF375F"),
        CategorySeed(name: "餐饮", symbolName: "fork.knife", colorHex: "#FF9F0A"),
        CategorySeed(name: "交通", symbolName: "car.fill", colorHex: "#0A84FF"),
        CategorySeed(name: "购物", symbolName: "bag.fill", colorHex: "#FF375F"),
        CategorySeed(name: "居住", symbolName: "house.fill", colorHex: "#5E5CE6"),
        CategorySeed(name: "娱乐", symbolName: "gamecontroller.fill", colorHex: "#BF5AF2"),
        CategorySeed(name: "医疗", symbolName: "cross.case.fill", colorHex: "#FF453A"),
        CategorySeed(name: "学习", symbolName: "book.fill", colorHex: "#64D2FF"),
        CategorySeed(name: "通讯", symbolName: "antenna.radiowaves.left.and.right", colorHex: "#30D158"),
        CategorySeed(name: "其他支出", symbolName: "ellipsis.circle", colorHex: "#8E8E93"),
    ]

    static let incomeCategories: [CategorySeed] = [
        CategorySeed(name: "红包", symbolName: "gift.fill", colorHex: "#FF375F"),
        CategorySeed(name: "工资", symbolName: "banknote.fill", colorHex: "#30D158"),
        CategorySeed(name: "奖金", symbolName: "gift.fill", colorHex: "#FFD60A"),
        CategorySeed(name: "理财收益", symbolName: "chart.line.uptrend.xyaxis", colorHex: "#0A84FF"),
        CategorySeed(name: "报销", symbolName: "doc.text.fill", colorHex: "#64D2FF"),
        CategorySeed(name: "其他收入", symbolName: "ellipsis.circle", colorHex: "#8E8E93"),
    ]

    /// 内置分类的版本号：新增内置分类时递增，并在 `addedCategories` 中登记。
    static let currentCategoryVersion = 2

    /// 各版本新增的内置分类，用于给已有的数据库补齐。
    static let addedCategories: [Int: [(kind: CategoryKind, seed: CategorySeed)]] = [
        2: [
            (.expense, CategorySeed(name: "红包", symbolName: "gift.fill", colorHex: "#FF375F")),
            (.income, CategorySeed(name: "红包", symbolName: "gift.fill", colorHex: "#FF375F")),
        ],
    ]

    /// 幂等：已有账户与分类不会被重复写入，也不会覆盖用户的修改。
    static func seedIfNeeded(in context: ModelContext) throws {
        let accountCount = try context.fetchCount(FetchDescriptor<Account>())
        let categoryCount = try context.fetchCount(FetchDescriptor<EntryCategory>())
        let storedVersion = UserDefaults.standard.integer(forKey: PreferenceKeys.defaultCategoriesVersion)

        var didChange = false

        if accountCount == 0 {
            context.insert(
                Account(
                    name: "现金",
                    kind: .cash,
                    initialBalance: .zero,
                    colorHex: Palette.accountColors[1],
                    sortOrder: 0
                )
            )
            didChange = true
        }

        if categoryCount == 0 {
            insert(expenseCategories, kind: .expense, in: context)
            insert(incomeCategories, kind: .income, in: context)
            didChange = true
        } else if storedVersion < currentCategoryVersion {
            // 已有的库：只补上新增的内置分类，用户自己删掉的分类不会复活。
            let existing = try context.fetch(FetchDescriptor<EntryCategory>())
            var nextSortOrder = (existing.map(\.sortOrder).max() ?? 0) + 1
            for version in (storedVersion + 1)...currentCategoryVersion {
                for item in addedCategories[version] ?? [] {
                    let alreadyExists = existing.contains { $0.kind == item.kind && $0.name == item.seed.name }
                    guard !alreadyExists else { continue }
                    context.insert(
                        EntryCategory(
                            name: item.seed.name,
                            kind: item.kind,
                            symbolName: item.seed.symbolName,
                            colorHex: item.seed.colorHex,
                            sortOrder: nextSortOrder
                        )
                    )
                    nextSortOrder += 1
                    didChange = true
                }
            }
        }

        if didChange {
            try context.save()
        }
        UserDefaults.standard.set(currentCategoryVersion, forKey: PreferenceKeys.defaultCategoriesVersion)
    }

    private static func insert(_ seeds: [CategorySeed], kind: CategoryKind, in context: ModelContext) {
        for (index, seed) in seeds.enumerated() {
            context.insert(
                EntryCategory(
                    name: seed.name,
                    kind: kind,
                    symbolName: seed.symbolName,
                    colorHex: seed.colorHex,
                    sortOrder: index
                )
            )
        }
    }

    /// 清空全部数据并重新写入默认账户与分类。
    static func resetAll(in context: ModelContext) throws {
        // 逐个删除而不是批量删除：批量删除会绕过关系逆操作，触发
        // “mandatory OTO nullify inverse” 约束错误。
        for entry in try context.fetch(FetchDescriptor<Entry>()) {
            context.delete(entry)
        }
        try context.save()

        for account in try context.fetch(FetchDescriptor<Account>()) {
            context.delete(account)
        }
        for category in try context.fetch(FetchDescriptor<EntryCategory>()) {
            context.delete(category)
        }
        try context.save()

        try seedIfNeeded(in: context)
    }
}
