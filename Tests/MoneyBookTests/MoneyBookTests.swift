import Foundation
import SwiftData
import Testing

@testable import MoneyBook

// MARK: - 测试工具

@MainActor
private func makeContext() throws -> ModelContext {
    let container = try PersistenceController.makeContainer(inMemory: true)
    return ModelContext(container)
}

private func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "zh_CN")
    return calendar
}

private func makeDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 12,
    _ minute: Int = 0,
    calendar: Calendar
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

private func dec(_ text: String) -> Decimal {
    Decimal(string: text)!
}

// MARK: - 余额与转账

@MainActor
@Suite("余额与转账")
struct BalanceTests {
    @Test("期初余额按收入与支出累加")
    func balanceAddsIncomeAndExpense() throws {
        let context = try makeContext()
        let account = Account(name: "现金", kind: .cash, initialBalance: dec("1000"))
        let salary = EntryCategory(name: "工资", kind: .income)
        let food = EntryCategory(name: "餐饮", kind: .expense)
        context.insert(account)
        context.insert(salary)
        context.insert(food)

        context.insert(Entry(date: .now, kind: .income, amount: dec("500"), category: salary, account: account))
        context.insert(Entry(date: .now, kind: .expense, amount: dec("200"), category: food, account: account))
        try context.save()

        #expect(BalanceService.balance(of: account) == dec("1300"))
        #expect(BalanceService.netWorth(accounts: [account]) == dec("1300"))
    }

    @Test("转账只改变账户余额，不改变净资产")
    func transferMovesBalanceWithoutChangingNetWorth() throws {
        let context = try makeContext()
        let cash = Account(name: "现金", kind: .cash, initialBalance: dec("1000"))
        let card = Account(name: "银行卡", kind: .bankCard, initialBalance: dec("0"))
        context.insert(cash)
        context.insert(card)

        let transfer = Entry(date: .now, kind: .transfer, amount: dec("300"), account: cash, toAccount: card)
        context.insert(transfer)
        try context.save()

        #expect(BalanceService.balance(of: cash) == dec("700"))
        #expect(BalanceService.balance(of: card) == dec("300"))
        #expect(BalanceService.netWorth(accounts: [cash, card]) == dec("1000"))

        let totals = StatisticsService.periodTotals(entries: [transfer])
        #expect(totals.income == .zero)
        #expect(totals.expense == .zero)
    }

    @Test("信用卡允许负余额")
    func creditCardAllowsNegativeBalance() throws {
        let context = try makeContext()
        let card = Account(name: "信用卡", kind: .creditCard, initialBalance: dec("0"))
        let shopping = EntryCategory(name: "购物", kind: .expense)
        context.insert(card)
        context.insert(shopping)
        context.insert(Entry(date: .now, kind: .expense, amount: dec("888.88"), category: shopping, account: card))
        try context.save()

        #expect(AccountKind.creditCard.allowsNegativeBalance)
        #expect(BalanceService.balance(of: card) == dec("-888.88"))
    }
}

// MARK: - 录入校验

@MainActor
@Suite("录入校验")
struct ValidationTests {
    @Test("金额必须大于 0")
    func rejectsNonPositiveAmount() throws {
        let context = try makeContext()
        let account = Account(name: "现金")
        let category = EntryCategory(name: "餐饮", kind: .expense)
        context.insert(account)
        context.insert(category)

        #expect(throws: EntryValidationError.amountNotPositive) {
            try EntryValidator.validate(kind: .expense, amount: .zero, category: category, account: account)
        }
        #expect(throws: EntryValidationError.amountNotPositive) {
            try EntryValidator.validate(kind: .expense, amount: dec("-1"), category: category, account: account)
        }
    }

    @Test("支出与收入必须选择账户和分类")
    func requiresAccountAndCategory() throws {
        let context = try makeContext()
        let account = Account(name: "现金")
        let category = EntryCategory(name: "餐饮", kind: .expense)
        context.insert(account)
        context.insert(category)

        #expect(throws: EntryValidationError.missingAccount) {
            try EntryValidator.validate(kind: .expense, amount: dec("1"), category: category, account: nil)
        }
        #expect(throws: EntryValidationError.missingCategory) {
            try EntryValidator.validate(kind: .expense, amount: dec("1"), category: nil, account: account)
        }
    }

    @Test("转账两端不能是同一个账户")
    func rejectsSameTransferAccount() throws {
        let context = try makeContext()
        let account = Account(name: "现金")
        context.insert(account)

        #expect(throws: EntryValidationError.sameTransferAccount) {
            try EntryValidator.validate(kind: .transfer, amount: dec("1"), category: nil, account: account, toAccount: account)
        }
        #expect(throws: EntryValidationError.missingTransferDestination) {
            try EntryValidator.validate(kind: .transfer, amount: dec("1"), category: nil, account: account, toAccount: nil)
        }
    }

    @Test("金额统一保留两位小数")
    func roundsAmountToCents() throws {
        #expect(dec("0.1").roundedToCents() + dec("0.2").roundedToCents() == dec("0.3"))
        #expect(Entry(date: .now, kind: .expense, amount: dec("12.345")).amount == dec("12.35"))
        #expect(Entry(date: .now, kind: .expense, amount: dec("12.344")).amount == dec("12.34"))
    }
}

// MARK: - 归档与删除保护

@MainActor
@Suite("归档与删除保护")
struct ArchiveTests {
    @Test("被引用的账户与分类禁止硬删除")
    func blocksDeletionWhenReferenced() throws {
        let context = try makeContext()
        let account = Account(name: "现金")
        let category = EntryCategory(name: "餐饮", kind: .expense)
        let emptyAccount = Account(name: "备用卡")
        let emptyCategory = EntryCategory(name: "宠物", kind: .expense)
        context.insert(account)
        context.insert(category)
        context.insert(emptyAccount)
        context.insert(emptyCategory)
        context.insert(Entry(date: .now, kind: .expense, amount: dec("10"), category: category, account: account))
        try context.save()

        #expect(DeletionGuard.canDelete(account) == false)
        #expect(DeletionGuard.canDelete(category) == false)
        #expect(DeletionGuard.blockingEntryCount(for: account) == 1)
        #expect(DeletionGuard.canDelete(emptyAccount))
        #expect(DeletionGuard.canDelete(emptyCategory))
    }

    @Test("归档账户与分类后历史流水仍计入余额与统计")
    func archivedItemsStillCounted() throws {
        let context = try makeContext()
        let account = Account(name: "旧卡", initialBalance: dec("100"))
        let category = EntryCategory(name: "餐饮", kind: .expense)
        account.isArchived = true
        category.isArchived = true
        context.insert(account)
        context.insert(category)
        context.insert(Entry(date: .now, kind: .expense, amount: dec("40"), category: category, account: account))
        try context.save()

        #expect(BalanceService.balance(of: account) == dec("60"))
        #expect(StatisticsService.periodTotals(entries: category.entries).expense == dec("40"))
        #expect(StatisticsService.categoryBreakdown(entries: category.entries, kind: .expense).count == 1)
    }
}

// MARK: - 统计与时间边界

@MainActor
@Suite("统计与时间边界")
struct StatisticsTests {
    @Test("跨月与跨年归属正确，无数据月份补零")
    func monthlyBucketsRespectBoundaries() throws {
        let context = try makeContext()
        let calendar = fixedCalendar()
        let account = Account(name: "现金")
        let category = EntryCategory(name: "餐饮", kind: .expense)
        context.insert(account)
        context.insert(category)

        // 2 月最后一天 23:59 属于 2 月；3 月 1 日 00:00 属于 3 月；去年 12 月不在范围内。
        context.insert(Entry(date: makeDate(2026, 2, 28, 23, 59, calendar: calendar), kind: .expense, amount: dec("10"), category: category, account: account))
        context.insert(Entry(date: makeDate(2026, 3, 1, 0, 0, calendar: calendar), kind: .expense, amount: dec("20"), category: category, account: account))
        context.insert(Entry(date: makeDate(2025, 12, 31, 23, 59, calendar: calendar), kind: .expense, amount: dec("99"), category: category, account: account))
        try context.save()

        let entries = try context.fetch(FetchDescriptor<Entry>())
        let totals = StatisticsService.monthlyTotals(
            entries: entries,
            months: 3,
            endingOn: makeDate(2026, 3, 15, calendar: calendar),
            calendar: calendar
        )

        #expect(totals.count == 3)
        #expect(totals.map(\.expense) == [dec("0"), dec("10"), dec("20")])
        #expect(totals.first?.month == calendar.dateInterval(of: .month, for: makeDate(2026, 1, 15, calendar: calendar))?.start)
    }

    @Test("分类合计与支出合计一致，并按金额降序")
    func categoryBreakdownMatchesTotals() throws {
        let context = try makeContext()
        let account = Account(name: "现金")
        let food = EntryCategory(name: "餐饮", kind: .expense)
        let transport = EntryCategory(name: "交通", kind: .expense)
        let salary = EntryCategory(name: "工资", kind: .income)
        for item in [account] { context.insert(item) }
        for item in [food, transport, salary] { context.insert(item) }

        context.insert(Entry(date: .now, kind: .expense, amount: dec("30"), category: food, account: account))
        context.insert(Entry(date: .now, kind: .expense, amount: dec("70"), category: food, account: account))
        context.insert(Entry(date: .now, kind: .expense, amount: dec("50"), category: transport, account: account))
        context.insert(Entry(date: .now, kind: .income, amount: dec("900"), category: salary, account: account))
        try context.save()

        let entries = try context.fetch(FetchDescriptor<Entry>())
        let expenseTotal = StatisticsService.periodTotals(entries: entries).expense
        let breakdown = StatisticsService.categoryBreakdown(entries: entries, kind: .expense)

        #expect(expenseTotal == dec("150"))
        #expect(breakdown.map(\.amount) == [dec("100"), dec("50")])
        #expect(breakdown.map(\.name) == ["餐饮", "交通"])
        #expect(breakdown.reduce(Decimal.zero) { $0 + $1.amount } == expenseTotal)
        #expect(StatisticsService.categoryBreakdown(entries: entries, kind: .income).count == 1)
    }

    @Test("没有数据时不崩溃、不做除零运算")
    func handlesEmptyData() throws {
        let context = try makeContext()
        #expect(StatisticsService.categoryBreakdown(entries: [], kind: .expense).isEmpty)
        #expect(StatisticsService.periodTotals(entries: []) == PeriodTotals.zero)
        #expect(StatisticsService.monthlyTotals(entries: [], months: 0).isEmpty)

        let totals = StatisticsService.monthlyTotals(entries: [], months: 6, endingOn: .now, calendar: fixedCalendar())
        #expect(totals.count == 6)
        #expect(totals.allSatisfy { $0.income == .zero && $0.expense == .zero && $0.net == .zero })

        let account = Account(name: "空账户")
        context.insert(account)
        try context.save()
        #expect(BalanceService.balance(of: account) == .zero)
    }

    @Test("无分类的支出归入未分类桶")
    func uncategorizedExpenseIsGrouped() throws {
        let context = try makeContext()
        let account = Account(name: "现金")
        context.insert(account)
        context.insert(Entry(date: .now, kind: .expense, amount: dec("9.99"), category: nil, account: account))
        try context.save()

        let entries = try context.fetch(FetchDescriptor<Entry>())
        let breakdown = StatisticsService.categoryBreakdown(entries: entries, kind: .expense)
        #expect(breakdown.count == 1)
        #expect(breakdown.first?.categoryID == StatisticsService.uncategorizedID)
        #expect(breakdown.first?.name == "未分类")
    }

    @Test("流水筛选：账户、分类、类型与关键词")
    func filterMatchesEntries() throws {
        let context = try makeContext()
        let cash = Account(name: "现金")
        let card = Account(name: "工资卡")
        let food = EntryCategory(name: "餐饮", kind: .expense)
        let salary = EntryCategory(name: "工资", kind: .income)
        for item in [cash, card] { context.insert(item) }
        for item in [food, salary] { context.insert(item) }

        let lunch = Entry(date: .now, kind: .expense, amount: dec("25"), category: food, account: cash, note: "楼下麻辣烫")
        let pay = Entry(date: .now, kind: .income, amount: dec("9000"), category: salary, account: card, note: "九月工资")
        let transfer = Entry(date: .now, kind: .transfer, amount: dec("500"), account: card, toAccount: cash, note: "取现")
        for entry in [lunch, pay, transfer] { context.insert(entry) }
        try context.save()

        var filter = EntryFilter()
        filter.searchText = "麻辣"
        #expect(filter.apply(to: [lunch, pay, transfer]).map(\.uuid) == [lunch.uuid])

        filter = EntryFilter()
        filter.accountID = cash.uuid
        #expect(filter.apply(to: [lunch, pay, transfer]).count == 2)

        filter = EntryFilter()
        filter.kind = .transfer
        #expect(filter.apply(to: [lunch, pay, transfer]).map(\.uuid) == [transfer.uuid])

        filter = EntryFilter()
        filter.categoryID = salary.uuid
        #expect(filter.apply(to: [lunch, pay, transfer]).map(\.uuid) == [pay.uuid])

        filter = EntryFilter()
        filter.range = DateInterval(start: Date().addingTimeInterval(3600), duration: 60)
        #expect(filter.apply(to: [lunch, pay, transfer]).isEmpty)
    }
}

// MARK: - 种子数据与规模

@MainActor
@Suite("种子数据与规模")
struct SeedAndScaleTests {
    @Test("磁盘数据库在重新打开后数据仍在")
    func diskPersistenceSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoneyBookTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try PersistenceController.makeContainer(at: directory)
            let context = ModelContext(container)
            try SeedDataService.seedIfNeeded(in: context)

            let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
            let category = try #require(try context.fetch(FetchDescriptor<EntryCategory>()).first)
            context.insert(
                Entry(date: .now, kind: .expense, amount: dec("66.66"), category: category, account: account)
            )
            try context.save()

            #expect(BalanceService.balance(of: account) == dec("-66.66"))
        }

        let reopened = try PersistenceController.makeContainer(at: directory)
        let context = ModelContext(reopened)
        let entries = try context.fetch(FetchDescriptor<Entry>())
        let accounts = try context.fetch(FetchDescriptor<Account>())

        #expect(entries.count == 1)
        #expect(entries.first?.amount == dec("66.66"))
        #expect(accounts.count == 1)
        #expect(BalanceService.balance(of: try #require(accounts.first)) == dec("-66.66"))
    }

    @Test("默认数据幂等：重复写入不产生重复项")
    func seedingIsIdempotent() throws {
        let context = try makeContext()
        try SeedDataService.seedIfNeeded(in: context)
        let accountsAfterFirst = try context.fetchCount(FetchDescriptor<Account>())
        let categoriesAfterFirst = try context.fetchCount(FetchDescriptor<EntryCategory>())

        try SeedDataService.seedIfNeeded(in: context)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == accountsAfterFirst)
        #expect(try context.fetchCount(FetchDescriptor<EntryCategory>()) == categoriesAfterFirst)
        #expect(accountsAfterFirst == 1)
        #expect(categoriesAfterFirst == SeedDataService.expenseCategories.count + SeedDataService.incomeCategories.count)
    }

    @Test("清空数据后重新写入默认项")
    func resetRestoresDefaults() throws {
        let context = try makeContext()
        try SeedDataService.seedIfNeeded(in: context)
        let account = try #require(try context.fetch(FetchDescriptor<Account>()).first)
        let category = try #require(try context.fetch(FetchDescriptor<EntryCategory>()).first)
        context.insert(Entry(date: .now, kind: .expense, amount: dec("5"), category: category, account: account))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)

        try SeedDataService.resetAll(in: context)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Account>()) == 1)
        #expect(BalanceService.balance(of: try #require(try context.fetch(FetchDescriptor<Account>()).first)) == .zero)
    }

    @Test("5000 笔流水下月度汇总在 1 秒内完成")
    func monthlyAggregationScales() throws {
        let context = try makeContext()
        let calendar = fixedCalendar()
        let account = Account(name: "现金")
        let food = EntryCategory(name: "餐饮", kind: .expense)
        let salary = EntryCategory(name: "工资", kind: .income)
        context.insert(account)
        context.insert(food)
        context.insert(salary)

        let end = makeDate(2026, 12, 15, calendar: calendar)
        for index in 0..<5_000 {
            let dayOffset = index % 360
            let date = calendar.date(byAdding: .day, value: -dayOffset, to: end)!
            let isIncome = index % 5 == 0
            context.insert(
                Entry(
                    date: date,
                    kind: isIncome ? .income : .expense,
                    amount: dec("\(index % 500 + 1).\(index % 100)"),
                    category: isIncome ? salary : food,
                    account: account
                )
            )
        }
        try context.save()

        let entries = try context.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 5_000)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = StatisticsService.monthlyTotals(entries: entries, months: 12, endingOn: end, calendar: calendar)
        }
        #expect(elapsed < .seconds(1))
    }
}
