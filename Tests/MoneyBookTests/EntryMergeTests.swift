import Foundation
import SwiftData
import Testing

@testable import MoneyBook

@MainActor
private func makeMergeContext() throws -> (ModelContext, [Account], [EntryCategory]) {
    let container = try PersistenceController.makeContainer(inMemory: true)
    let context = ModelContext(container)
    try SeedDataService.seedIfNeeded(in: context)
    let accounts = try context.fetch(FetchDescriptor<Account>())
    let categories = try context.fetch(FetchDescriptor<EntryCategory>())
    return (context, accounts, categories)
}

private func category(_ categories: [EntryCategory], _ name: String, _ kind: CategoryKind) -> EntryCategory {
    categories.first { $0.name == name && $0.kind == kind }!
}

@MainActor
@Suite("流水合并")
struct EntryMergeTests {
    /// 典型 AA 场景：自己先付 300，两位朋友各还 100。
    private func makeGroupDinner(
        _ context: ModelContext,
        _ accounts: [Account],
        _ categories: [EntryCategory]
    ) -> (bill: Entry, repayA: Entry, repayB: Entry) {
        let card = accounts.first { $0.name == "现金" }!
        let wallet = Account(name: "微信零钱", kind: .eWallet)
        context.insert(wallet)

        let dinner = Entry(
            date: makeDate(2026, 9, 10, 19, 30),
            kind: .expense,
            amount: Decimal(string: "300")!,
            category: category(categories, "餐饮", .expense),
            account: card,
            note: "聚餐"
        )
        let repayA = Entry(
            date: makeDate(2026, 9, 12, 10, 0),
            kind: .income,
            amount: Decimal(string: "100")!,
            category: category(categories, "其他收入", .income),
            account: wallet,
            note: "小李还"
        )
        let repayB = Entry(
            date: makeDate(2026, 9, 12, 11, 0),
            kind: .income,
            amount: Decimal(string: "100")!,
            category: category(categories, "其他收入", .income),
            account: wallet,
            note: "小王还"
        )
        for entry in [dinner, repayA, repayB] { context.insert(entry) }
        try? context.save()
        return (dinner, repayA, repayB)
    }

    @Test("净额计算：支出为负、收入为正")
    func computesNetAmount() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let group = makeGroupDinner(context, accounts, categories)

        #expect(EntryMergeService.netAmount(of: [group.bill]) == Decimal(string: "-300"))
        #expect(EntryMergeService.netAmount(of: [group.bill, group.repayA, group.repayB]) == Decimal(string: "-100"))
        #expect(EntryMergeService.netAmount(of: [group.repayA, group.repayB]) == Decimal(string: "200"))
    }

    @Test("校验：不足两笔、含转账、净额为零都会拒绝")
    func validatesSelection() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let group = makeGroupDinner(context, accounts, categories)
        let card = accounts.first { $0.name == "现金" }!

        #expect(throws: EntryMergeService.MergeError.notEnoughEntries) {
            try EntryMergeService.validate([group.bill])
        }

        let transfer = Entry(
            date: Date(),
            kind: .transfer,
            amount: Decimal(string: "50")!,
            account: card,
            toAccount: accounts.first { $0.uuid != card.uuid }
        )
        context.insert(transfer)
        #expect(throws: EntryMergeService.MergeError.containsTransfer) {
            try EntryMergeService.validate([group.bill, transfer])
        }

        // 支出 100 + 收入 100 = 0
        let offsetting = Entry(
            date: Date(),
            kind: .income,
            amount: Decimal(string: "300")!,
            category: category(categories, "其他收入", .income),
            account: card
        )
        context.insert(offsetting)
        #expect(throws: EntryMergeService.MergeError.zeroNetAmount) {
            try EntryMergeService.validate([group.bill, offsetting])
        }
    }

    @Test("默认值：金额取净额，分类与账户取金额最大的一笔，日期取最早一笔")
    func suggestsDraftDefaults() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let group = makeGroupDinner(context, accounts, categories)
        let fallback = category(categories, "其他支出", .expense)

        let draft = EntryMergeService.draft(for: [group.bill, group.repayA, group.repayB], defaultCategory: fallback)
        #expect(draft.kind == .expense)
        #expect(draft.amount == Decimal(string: "100"))
        #expect(draft.category?.name == "餐饮")
        #expect(draft.account?.name == "现金")
        #expect(draft.date == group.bill.date)
        #expect(draft.note == "聚餐")
    }

    @Test("合并后只剩一条净额流水，并可撤销还原")
    func mergesAndRestores() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let group = makeGroupDinner(context, accounts, categories)
        let originalCount = try context.fetchCount(FetchDescriptor<Entry>())

        let draft = EntryMergeService.draft(
            for: [group.bill, group.repayA, group.repayB],
            defaultCategory: category(categories, "其他支出", .expense)
        )
        let merged = try EntryMergeService.merge([group.bill, group.repayA, group.repayB], draft: draft, context: context)

        let entries = try context.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == originalCount - 2)
        #expect(merged.kind == .expense)
        #expect(merged.amount == Decimal(string: "100"))
        #expect(merged.category?.name == "餐饮")
        #expect(merged.note == "聚餐")
        #expect(merged.isMergeResult)
        #expect(merged.mergedSourceCount == 3)
        #expect(EntryMergeService.sourceCount(of: merged) == 3)

        let restored = try EntryMergeService.undo(merged, context: context)
        #expect(restored == 3)

        let afterUndo = try context.fetch(FetchDescriptor<Entry>())
        #expect(afterUndo.count == originalCount)
        #expect(afterUndo.contains { $0.note == "聚餐" && $0.amount == Decimal(string: "300") })
        #expect(afterUndo.contains { $0.note == "小李还" })
        #expect(afterUndo.contains { $0.note == "小王还" })
        #expect(afterUndo.contains { $0.isMergeResult } == false)
    }

    @Test("撤销后明细金额与净资产都复原")
    func undoRestoresBalances() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let group = makeGroupDinner(context, accounts, categories)

        let allAccounts = try context.fetch(FetchDescriptor<Account>())
        let before = BalanceService.netWorth(accounts: allAccounts)

        let draft = EntryMergeService.draft(
            for: [group.bill, group.repayA, group.repayB],
            defaultCategory: category(categories, "其他支出", .expense)
        )
        let merged = try EntryMergeService.merge([group.bill, group.repayA, group.repayB], draft: draft, context: context)
        #expect(BalanceService.netWorth(accounts: allAccounts) == before)

        _ = try EntryMergeService.undo(merged, context: context)
        #expect(BalanceService.netWorth(accounts: allAccounts) == before)
    }

    @Test("同一账户内合并不会改变账户余额")
    func mergingWithinOneAccountKeepsBalance() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let card = accounts.first { $0.name == "现金" }!

        let first = Entry(
            date: makeDate(2026, 9, 10, 12, 0),
            kind: .expense,
            amount: Decimal(string: "50")!,
            category: category(categories, "餐饮", .expense),
            account: card
        )
        let second = Entry(
            date: makeDate(2026, 9, 10, 18, 0),
            kind: .expense,
            amount: Decimal(string: "30")!,
            category: category(categories, "餐饮", .expense),
            account: card
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let before = BalanceService.balance(of: card)
        let draft = EntryMergeService.draft(for: [first, second], defaultCategory: nil)
        let merged = try EntryMergeService.merge([first, second], draft: draft, context: context)

        #expect(merged.amount == Decimal(string: "80"))
        #expect(merged.category?.name == "餐饮")
        #expect(BalanceService.balance(of: card) == before)
    }

    @Test("合并嵌套：合并结果再合并仍可完整撤销")
    func supportsNestedMerges() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let card = accounts.first { $0.name == "现金" }!

        func expense(_ amount: String, note: String) -> Entry {
            Entry(
                date: Date(),
                kind: .expense,
                amount: Decimal(string: amount)!,
                category: category(categories, "餐饮", .expense),
                account: card,
                note: note
            )
        }
        let first = expense("10", note: "早餐")
        let second = expense("20", note: "午餐")
        let third = expense("30", note: "晚餐")
        for entry in [first, second, third] { context.insert(entry) }
        try context.save()

        let innerDraft = EntryMergeService.draft(for: [first, second], defaultCategory: nil)
        let inner = try EntryMergeService.merge([first, second], draft: innerDraft, context: context)
        let outerDraft = EntryMergeService.draft(for: [inner, third], defaultCategory: nil)
        let outer = try EntryMergeService.merge([inner, third], draft: outerDraft, context: context)

        #expect(outer.amount == Decimal(string: "60"))
        #expect(outer.mergedSourceCount == 2)

        // 撤销外层：内层合并结果与第三笔都回来
        #expect(try EntryMergeService.undo(outer, context: context) == 2)
        let afterOuterUndo = try context.fetch(FetchDescriptor<Entry>())
        #expect(afterOuterUndo.count == 2)

        // 再撤销内层：回到最初三笔
        let innerAgain = try #require(afterOuterUndo.first { $0.isMergeResult })
        #expect(try EntryMergeService.undo(innerAgain, context: context) == 2)
        let final = try context.fetch(FetchDescriptor<Entry>())
        #expect(final.count == 3)
        #expect(final.allSatisfy { !$0.isMergeResult })
    }

    @Test("被合并掉的导入流水，重新导入时仍然算重复")
    func keepsImportDeduplication() throws {
        let (context, accounts, categories) = try makeMergeContext()
        let wallet = accounts.first { $0.name == "现金" }!

        let first = Entry(
            date: makeDate(2026, 9, 10, 10, 0),
            kind: .income,
            amount: Decimal(string: "100")!,
            category: category(categories, "其他收入", .income),
            account: wallet,
            externalID: "wechat:4200000000000000001"
        )
        let second = Entry(
            date: makeDate(2026, 9, 10, 11, 0),
            kind: .income,
            amount: Decimal(string: "100")!,
            category: category(categories, "其他收入", .income),
            account: wallet,
            externalID: "wechat:4200000000000000002"
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let draft = EntryMergeService.draft(for: [first, second], defaultCategory: nil)
        let merged = try EntryMergeService.merge([first, second], draft: draft, context: context)
        #expect(merged.externalID == nil)
        #expect(Set(EntryMergeService.mergedExternalIDs(of: merged))
            == ["wechat:4200000000000000001", "wechat:4200000000000000002"])

        // 用同样的单号导一次账单，应当全部判为重复。
        let csv = """
        交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
        2026/9/10 10:00:00,转账,朋友,还款,收入,¥100.00,零钱,已存入零钱,4200000000000000001,,
        2026/9/10 11:00:00,转账,朋友,还款,收入,¥100.00,零钱,已存入零钱,4200000000000000002,,
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-dedup-\(UUID().uuidString).csv")
        try csv.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try BillImportService.parse(url: url)
        let preview = try BillImportService.makePreview(parsed: parsed, fileName: "test.csv", context: context)
        #expect(preview.duplicateKeys.count == 2)
    }
}

private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}
