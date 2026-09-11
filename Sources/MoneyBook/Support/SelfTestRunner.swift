import Foundation
import SwiftData

/// 无界面自检：`MoneyBook --selftest`，用于在打包成 .app 前验证核心逻辑可用。
@MainActor
enum SelfTestRunner {
    static func run() -> Bool {
        do {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let context = ModelContext(container)
            try SeedDataService.seedIfNeeded(in: context)

            let accounts = try context.fetch(FetchDescriptor<Account>())
            let categories = try context.fetch(FetchDescriptor<EntryCategory>())
            guard let account = accounts.first, let category = categories.first else {
                print("SELFTEST FAILED: 默认数据未写入")
                return false
            }

            let entry = Entry(date: Date(), kind: .expense, amount: Decimal(string: "12.34")!, category: category, account: account)
            context.insert(entry)
            try context.save()

            let balance = BalanceService.balance(of: account)
            let totals = StatisticsService.periodTotals(entries: [entry])
            print("SELFTEST accounts=\(accounts.count) categories=\(categories.count) balance=\(balance) expense=\(totals.expense)")

            guard balance == Decimal(string: "-12.34")!, totals.expense == Decimal(string: "12.34")! else {
                print("SELFTEST FAILED: 余额或统计不正确")
                return false
            }
            print("SELFTEST OK")
            return true
        } catch {
            print("SELFTEST FAILED: \(error)")
            return false
        }
    }
}
