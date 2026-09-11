import Foundation
import SwiftData
import Testing

@testable import MoneyBook

@MainActor
private func makeBillContext() throws -> ModelContext {
    let container = try PersistenceController.makeContainer(inMemory: true)
    let context = ModelContext(container)
    try SeedDataService.seedIfNeeded(in: context)
    return context
}

private func writeTemporaryBillCSV(_ text: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MoneyBookBill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("bill.csv")
    try text.data(using: .utf8)!.write(to: url)
    return url
}

@MainActor
@Suite("账单导入落库")
struct BillImportTests {
    private func preview(for context: ModelContext, csv: String = sampleBillCSV) throws -> BillImportPreview {
        let url = try writeTemporaryBillCSV(csv)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let parsed = try BillImportService.parse(url: url)
        return try BillImportService.makePreview(parsed: parsed, fileName: url.lastPathComponent, context: context)
    }

    private func defaultOptions() -> BillImportOptions {
        BillImportOptions()
    }

    @Test("预览统计与账户计划")
    func buildsPreview() throws {
        let context = try makeBillContext()
        let preview = try preview(for: context)

        #expect(preview.rows.count == 4)
        #expect(preview.expenseTotal == Decimal(string: "45.80"))
        #expect(preview.incomeTotal == Decimal(string: "1000.00"))
        #expect(preview.neutralCount == 1)
        #expect(preview.accountPlans.contains { $0.accountName == "微信零钱" })
        #expect(preview.accountPlans.contains { $0.accountName == "工商银行(1234)" })
        #expect(preview.parseWarnings.isEmpty)
    }

    @Test("导入后写入流水、新建账户，中性交易变成转账")
    func appliesImport() throws {
        let context = try makeBillContext()
        let preview = try preview(for: context)
        let result = try BillImportService.apply(preview: preview, options: defaultOptions(), context: context)

        #expect(result.inserted == 4)
        #expect(result.expenseTotal == Decimal(string: "45.80"))
        #expect(result.incomeTotal == Decimal(string: "1000.00"))
        #expect(result.transferTotal == Decimal(string: "500.00"))
        #expect(result.createdAccountNames.contains("微信零钱"))
        #expect(result.createdAccountNames.contains("工商银行(1234)"))

        let entries = try context.fetch(FetchDescriptor<Entry>())
        #expect(entries.count == 4)

        let transfer = try #require(entries.first { $0.kind == .transfer })
        #expect(transfer.amount == Decimal(string: "500.00"))
        #expect(transfer.account?.name == "XX银行(1234)")
        #expect(transfer.toAccount?.name == "微信零钱")
        #expect(transfer.externalID != nil)
        #expect(transfer.importBatchID == result.batchID)

        let expense = try #require(entries.first { $0.kind == .expense && $0.amount == Decimal(string: "25.80") })
        #expect(expense.account?.name == "微信零钱")
        #expect(expense.category?.kind == .expense)
        #expect(expense.note.contains("某餐厅"))

        let income = try #require(entries.first { $0.kind == .income })
        #expect(income.category?.kind == .income)

        // 余额变化应等于收入 − 支出（转账只在账户间移动）。
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let wallet = try #require(accounts.first { $0.name == "微信零钱" })
        let walletBalance = BalanceService.balance(of: wallet)
        // −25.80（午餐）+ 1000.00（收入）+ 500.00（银行转入）
        #expect(walletBalance == Decimal(string: "1474.20"))
    }

    @Test("重复导入同一账单会被去重")
    func skipsDuplicates() throws {
        let context = try makeBillContext()
        let first = try preview(for: context)
        _ = try BillImportService.apply(preview: first, options: defaultOptions(), context: context)

        let second = try preview(for: context)
        #expect(second.duplicateKeys.count == 4)
        #expect(second.parseWarnings.contains { $0.contains("已经导入过") })

        let result = try BillImportService.apply(preview: second, options: defaultOptions(), context: context)
        #expect(result.inserted == 0)
        #expect(result.skippedDuplicates == 4)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 4)
    }

    @Test("撤销导入会删除本批流水与临时账户")
    func undoesImport() throws {
        let context = try makeBillContext()
        let preview = try preview(for: context)
        let result = try BillImportService.apply(preview: preview, options: defaultOptions(), context: context)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 4)

        let removed = BillImportService.undo(batchID: result.batchID, context: context)
        #expect(removed == 4)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 0)

        let accounts = try context.fetch(FetchDescriptor<Account>())
        #expect(accounts.contains { $0.name == "微信零钱" } == false)
        // 种子账户不受影响。
        #expect(accounts.contains { $0.name == "现金" })
    }

    @Test("退款记录默认跳过，可在选项中开启")
    func skipsRefundedRows() throws {
        let context = try makeBillContext()
        let refundCSV = sampleBillCSV.replacingOccurrences(of: "已存入零钱", with: "已全额退款")
        let preview = try preview(for: context, csv: refundCSV)

        var options = defaultOptions()
        var result = try BillImportService.apply(preview: preview, options: options, context: context)
        #expect(result.skippedRefunded == 1)
        #expect(result.inserted == 3)

        options.importRefundedRows = true
        options.skipDuplicates = false
        result = try BillImportService.apply(preview: preview, options: options, context: context)
        #expect(result.skippedRefunded == 0)
        #expect(result.inserted == 4)
    }

    @Test("中性交易可以关闭导入")
    func canDisableNeutralImport() throws {
        let context = try makeBillContext()
        let preview = try preview(for: context)
        var options = defaultOptions()
        options.importNeutralTransactions = false

        let result = try BillImportService.apply(preview: preview, options: options, context: context)
        #expect(result.inserted == 3)
        #expect(result.transferTotal == .zero)
        #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 3)
    }

    @Test("关键词自动分类")
    func autoCategorizes() throws {
        let context = try makeBillContext()
        let categories = try context.fetch(FetchDescriptor<EntryCategory>())

        var meal = BillRow(sourceLine: 1)
        meal.transactionType = "商户消费"
        meal.counterparty = "美团外卖"
        meal.product = "午餐"
        #expect(BillCategorizer.suggestedCategory(for: meal, direction: .expense, categories: categories)?.name == "餐饮")

        var salary = BillRow(sourceLine: 2)
        salary.counterparty = "某公司代发工资"
        #expect(BillCategorizer.suggestedCategory(for: salary, direction: .income, categories: categories)?.name == "工资")

        var unknown = BillRow(sourceLine: 3)
        unknown.counterparty = "某个不认识的小店"
        #expect(BillCategorizer.suggestedCategory(for: unknown, direction: .expense, categories: categories) == nil)
    }

    @Test("汇总不符时提示，小额优惠差异不提示")
    func validatesAgainstSummary() {
        let summary = BillSummary(
            totalCount: 13,
            incomeCount: 4,
            incomeTotal: Decimal(string: "380.00"),
            expenseCount: 6,
            expenseTotal: Decimal(string: "970.00"),
            neutralCount: 3,
            neutralTotal: Decimal(string: "1150.00")
        )

        let consistent = BillSummaryParser.discrepancyWarnings(
            summary: summary,
            expense: Decimal(string: "970.00")!,
            income: Decimal(string: "380.00")!,
            neutral: Decimal(string: "1150.00")!,
            importedRowCount: 13
        )
        #expect(consistent.isEmpty)

        // 优惠造成的 5 元差异远小于总额的 1%，不提示。
        let discounted = BillSummaryParser.discrepancyWarnings(
            summary: summary,
            expense: Decimal(string: "965.00")!,
            income: Decimal(string: "380.00")!,
            neutral: Decimal(string: "1150.00")!,
            importedRowCount: 13
        )
        #expect(discounted.isEmpty)

        // OCR 把 ¥10.00 读成 1000 这类错误必须被发现。
        let mismatch = BillSummaryParser.discrepancyWarnings(
            summary: summary,
            expense: Decimal(string: "970.00")!,
            income: Decimal(string: "1370.00")!,
            neutral: Decimal(string: "1150.00")!,
            importedRowCount: 13
        )
        #expect(mismatch.contains { $0.contains("收入合计") })
    }

    @Test("账户名匹配忽略「微信」前缀与空格")
    func matchesAccounts() throws {
        let context = try makeBillContext()
        let account = Account(name: "零钱", kind: .eWallet)
        context.insert(account)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Account>())
        #expect(BillImportService.matchAccount(named: "微信零钱", in: all)?.uuid == account.uuid)
        #expect(BillImportService.tidyAccountName("XX银行 （1234）") == "XX银行(1234)")
        #expect(BillImportService.inferAccountKind(from: "招商银行信用卡") == .creditCard)
        #expect(BillImportService.inferAccountKind(from: "微信零钱") == .eWallet)
    }

    @Test("中性交易的资金流向映射")
    func mapsNeutralTransfers() {
        var topUp = BillRow(sourceLine: 1)
        topUp.transactionType = "零钱充值"
        topUp.paymentMethod = "XX银行(1234)"
        #expect(BillImportService.transferAccounts(for: topUp).from == "XX银行(1234)")
        #expect(BillImportService.transferAccounts(for: topUp).to == "微信零钱")

        var withdraw = BillRow(sourceLine: 2)
        withdraw.transactionType = "零钱提现"
        withdraw.paymentMethod = "XX银行(1234)"
        #expect(BillImportService.transferAccounts(for: withdraw).from == "微信零钱")
        #expect(BillImportService.transferAccounts(for: withdraw).to == "XX银行(1234)")

        var repay = BillRow(sourceLine: 3)
        repay.transactionType = "信用卡还款"
        repay.paymentMethod = "零钱"
        repay.counterparty = "招商银行信用卡还款"
        #expect(BillImportService.transferAccounts(for: repay).from == "微信零钱")
        #expect(BillImportService.transferAccounts(for: repay).to == "招商银行信用卡")
    }
}
