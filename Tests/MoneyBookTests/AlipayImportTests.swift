import Foundation
import SwiftData
import Testing

@testable import MoneyBook

/// 支付宝「交易明细」导出：GBK 编码、前言为 CRLF、明细行以 LF 结尾。
private let sampleAlipayCSV = [
    "------------------------------------------------------------------------------------\r",
    "导出信息：\r",
    "姓名：张三\r",
    "支付宝账户：13800000000\r",
    "起始时间：[2026-09-01 00:00:00]    终止时间：[2026-09-12 23:59:59]\r",
    "导出交易类型：[全部]\r",
    "导出时间：[2026-09-12 09:21:20]\r",
    "共4笔记录\r",
    "收入：1笔 88.00元\r",
    "支出：2笔 12.70元\r",
    "不计收支：1笔 100.00元\r",
    "\r",
    "特别提示：\r",
    "1.本回单内容可表明支付宝受理了相应支付交易申请；\r",
    "------------------------支付宝支付科技有限公司  电子客户回单------------------------\r",
    "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,",
    "2026-09-12 00:30:40,数码电器,海乐生活,yun***@163.com,海乐生活,支出,4.90,账户余额&碰一下立减,交易成功,2026091223001444721425435520\t,2026091200304011012524399864\t,,",
    "2026-09-11 09:55:04,交通出行,上海公共交通卡,abc@example.com,上海地铁,支出,7.80,账户余额(个人余额),交易成功,2026091123001444721424188051\t,17202609110954560000\t,,",
    "2026-09-10 18:40:26,转账,朋友甲,friend@example.com,\"转账, 备注\",收入,88.00,账户余额,交易成功,2026091023001444721424235097\t,,,",
    "2026-09-09 10:00:00,充值,招商银行储蓄卡,bank@example.com,充值,不计收支,100.00,招商银行储蓄卡(1234),交易成功,2026090923001444721424235098\t,,,",
].joined(separator: "\n") + "\n"

private func gb18030() -> String.Encoding {
    String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}

private func writeAlipayFixture(_ text: String, encoding: String.Encoding) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MoneyBookAlipay-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("alipay.csv")
    try text.data(using: encoding)!.write(to: url)
    return url
}

@Suite("CSV 词法")
struct CSVTextTests {
    @Test("CRLF、LF 与混合换行都能正确切分记录")
    func splitsRecordsWithMixedLineEndings() {
        #expect(CSVText.records(from: "a,b\r\nc,d\r\ne,f").count == 3)
        #expect(CSVText.records(from: "a,b\r\nc,d\ne,f").count == 3)
        #expect(CSVText.records(from: "a,b\nc,d").count == 2)

        let mixed = CSVText.records(from: "表头\r\n值一\r\n值二\n值三")
        #expect(mixed.map { $0[0] } == ["表头", "值一", "值二", "值三"])
    }

    @Test("引号包裹的字段保留逗号与换行")
    func keepsQuotedFields() {
        let records = CSVText.records(from: "a,\"b,c\",\"d\ne\"\n")
        #expect(records.count == 1)
        #expect(records[0] == ["a", "b,c", "d\ne"])
    }
}

@Suite("支付宝账单解析")
@MainActor
struct AlipayParserTests {
    @Test("GBK 编码 + 混合换行的真实结构能解析出明细与汇总")
    func parsesGBKFixture() throws {
        let url = try writeAlipayFixture(sampleAlipayCSV, encoding: gb18030())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parsed = try BillImportService.parse(url: url)
        #expect(parsed.platform == .alipay)
        #expect(parsed.source == .csv)
        #expect(parsed.rows.count == 4)

        let first = try #require(parsed.rows.first)
        #expect(first.transactionType == "数码电器")
        #expect(first.counterparty == "海乐生活")
        #expect(first.direction == .expense)
        #expect(first.amount == Decimal(string: "4.90"))
        #expect(first.paymentMethod == "账户余额&碰一下立减")
        #expect(first.status == "交易成功")
        // 单号后面带制表符，需要被清掉。
        #expect(first.transactionID == "2026091223001444721425435520")
        #expect(first.merchantID == "2026091200304011012524399864")
        #expect(first.issues.isEmpty)

        // 支付宝的「不计收支」是中性交易。
        let neutral = try #require(parsed.rows.first { $0.transactionType == "充值" })
        #expect(neutral.direction == .neutral)
        #expect(neutral.isNeutralTransaction)

        // 引号包裹的商品说明。
        let transfer = try #require(parsed.rows.first { $0.counterparty == "朋友甲" })
        #expect(transfer.product == "转账, 备注")
        #expect(transfer.direction == .income)

        let summary = try #require(parsed.summary)
        #expect(summary.totalCount == 4)
        #expect(summary.incomeTotal == Decimal(string: "88.00"))
        #expect(summary.expenseTotal == Decimal(string: "12.70"))
        // 「不计收支」也要能读成中性交易汇总。
        #expect(summary.neutralTotal == Decimal(string: "100.00"))
        #expect(summary.neutralCount == 1)
    }

    @Test("平台识别：支付宝与微信各自的表头")
    func detectsPlatform() {
        let alipay = [["交易时间", "交易分类", "交易对方", "对方账号", "商品说明", "收/支", "金额", "收/付款方式", "交易状态", "交易订单号", "商家订单号", "备注"]]
        #expect(BillPlatform.detect(from: alipay) == .alipay)

        let wechat = [["微信支付账单明细"], ["交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)", "支付方式", "当前状态", "交易单号", "商户单号", "备注"]]
        #expect(BillPlatform.detect(from: wechat) == .wechat)
    }

    @Test("支付方式映射到账户：主支付方式与平台钱包")
    func mapsPaymentMethods() {
        #expect(BillImportService.accountName(forPaymentMethod: "账户余额", platform: .alipay) == "支付宝余额")
        #expect(BillImportService.accountName(forPaymentMethod: "账户余额(个人余额)", platform: .alipay) == "支付宝余额")
        #expect(BillImportService.accountName(forPaymentMethod: "账户余额&红包", platform: .alipay) == "支付宝余额")
        #expect(BillImportService.accountName(forPaymentMethod: "账户余额&碰一下立减", platform: .alipay) == "支付宝余额")
        #expect(BillImportService.accountName(forPaymentMethod: "余额宝", platform: .alipay) == "余额宝")
        #expect(BillImportService.accountName(forPaymentMethod: "花呗", platform: .alipay) == "花呗")
        #expect(BillImportService.accountName(forPaymentMethod: "招商银行储蓄卡(1234)", platform: .alipay) == "招商银行储蓄卡(1234)")
        #expect(BillImportService.accountName(forPaymentMethod: "/", platform: .alipay) == "支付宝余额")

        // 微信侧保持不变。
        #expect(BillImportService.accountName(forPaymentMethod: "零钱", platform: .wechat) == "微信零钱")
        #expect(BillImportService.accountName(forPaymentMethod: "零钱通", platform: .wechat) == "微信零钱通")
    }

    @Test("支付宝交易分类直接映射到记账分类")
    func mapsPlatformCategories() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        try SeedDataService.seedIfNeeded(in: context)
        let categories = try context.fetch(FetchDescriptor<EntryCategory>())

        func category(_ platformCategory: String) -> String? {
            var row = BillRow(sourceLine: 1)
            row.transactionType = platformCategory
            row.product = "某商品"
            return BillCategorizer.suggestedCategory(for: row, direction: .expense, categories: categories)?.name
        }

        #expect(category("数码电器") == "购物")
        #expect(category("日用百货") == "购物")
        #expect(category("交通出行") == "交通")
        #expect(category("餐饮美食") == "餐饮")
        #expect(category("医疗健康") == "医疗")
        // 微信的交易类型不会被误映射。
        #expect(category("商户消费") == nil)
    }
}
