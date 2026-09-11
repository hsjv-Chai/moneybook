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
        CategorySeed(name: "工资", symbolName: "banknote.fill", colorHex: "#30D158"),
        CategorySeed(name: "奖金", symbolName: "gift.fill", colorHex: "#FFD60A"),
        CategorySeed(name: "理财收益", symbolName: "chart.line.uptrend.xyaxis", colorHex: "#0A84FF"),
        CategorySeed(name: "报销", symbolName: "doc.text.fill", colorHex: "#64D2FF"),
        CategorySeed(name: "其他收入", symbolName: "ellipsis.circle", colorHex: "#8E8E93"),
    ]

    /// 幂等：已经存在账户或分类时不再写入默认数据。
    static func seedIfNeeded(in context: ModelContext) throws {
        let accountCount = try context.fetchCount(FetchDescriptor<Account>())
        let categoryCount = try context.fetchCount(FetchDescriptor<EntryCategory>())

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
            for (index, seed) in expenseCategories.enumerated() {
                context.insert(
                    EntryCategory(
                        name: seed.name,
                        kind: .expense,
                        symbolName: seed.symbolName,
                        colorHex: seed.colorHex,
                        sortOrder: index
                    )
                )
            }
            for (index, seed) in incomeCategories.enumerated() {
                context.insert(
                    EntryCategory(
                        name: seed.name,
                        kind: .income,
                        symbolName: seed.symbolName,
                        colorHex: seed.colorHex,
                        sortOrder: index
                    )
                )
            }
            didChange = true
        }

        if didChange {
            try context.save()
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
