import Foundation
import Testing

@testable import MoneyBook

/// 微信账单 CSV 示例（结构与官方导出一致，字段为构造数据）。
let sampleBillCSV = """
\u{FEFF}微信支付账单明细,,,,,,,,,,
微信昵称：[测试用户],,,,,,,,,,
起始时间：[2024-01-01 00:00:00] 终止时间：[2024-01-31 23:59:59],,,,,,,,,,
导出类型：[全部],,,,,,,,,,
导出时间：[2024-02-01 10:00:00],,,,,,,,,,
,,,,,,,,,,
共4笔记录,,,,,,,,,,
收入：1笔 1000.00元,,,,,,,,,,
支出：2笔 45.80元,,,,,,,,,,
中性交易：1笔 500.00元,,,,,,,,,,
注：,,,,,,,,,,
1.充值/提现/理财通购买/零钱通存取/信用卡还款等交易，将计入中性交易,,,,,,,,,,
2.若交易记录明细无有效内容，则代表该时间段内此微信号无交易。,,,,,,,,,,
3.本明细仅供个人对账使用,,,,,,,,,,
----------------------微信支付账单明细列表--------------------,,,,,,,,,,
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
2024/1/15 12:34:56,商户消费,某餐厅,"餐饮, 午餐",支出,¥25.80,零钱,支付成功,420000123420240115000000001,MM20240115001,
2024/1/16 09:00:00,转账,张三,1月房租,支出,¥20.00,工商银行(1234),支付成功,420000123420240116000000002,,
2024/1/20 10:00:00,转账,李四,还款,收入,¥1000.00,零钱,已存入零钱,420000123420240120000000003,,
2024/1/28 20:00:00,零钱充值,XX银行(1234),/,/,¥500.00,XX银行(1234),支付成功,420000123420240128000000004,,
"""

@Suite("微信账单 CSV 解析")
struct BillCSVParserTests {
    @Test("解析明细行、带引号的字段与金额")
    func parsesRows() throws {
        let rows = try WeChatCSVParser.rows(fromText: sampleBillCSV)
        #expect(rows.count == 4)

        let first = try #require(rows.first)
        #expect(first.transactionType == "商户消费")
        #expect(first.counterparty == "某餐厅")
        #expect(first.product == "餐饮, 午餐")
        #expect(first.direction == .expense)
        #expect(first.amount == Decimal(string: "25.80"))
        #expect(first.paymentMethod == "零钱")
        #expect(first.status == "支付成功")
        #expect(first.transactionID == "420000123420240115000000001")
        #expect(first.merchantID == "MM20240115001")
        #expect(first.date != nil)
        #expect(first.issues.isEmpty)

        let income = try #require(rows.first { $0.direction == .income })
        #expect(income.amount == Decimal(string: "1000.00"))

        let neutral = try #require(rows.first { $0.transactionType == "零钱充值" })
        #expect(neutral.direction == .neutral)
        #expect(neutral.isNeutralTransaction)
    }

    @Test("解析账单自带汇总")
    func parsesSummary() throws {
        let lines = sampleBillCSV.split(whereSeparator: \.isNewline).map(String.init)
        let summary = try #require(BillSummaryParser.parse(lines: lines))
        #expect(summary.totalCount == 4)
        #expect(summary.incomeTotal == Decimal(string: "1000.00"))
        #expect(summary.expenseTotal == Decimal(string: "45.80"))
        #expect(summary.neutralTotal == Decimal(string: "500.00"))
    }

    @Test("表头顺序变化时仍按列名取值")
    func mapsColumnsByName() throws {
        let text = """
        交易时间,收/支,交易类型,交易对方,商品,金额(元),支付方式,当前状态,交易单号,商户单号,备注
        2024/3/1 08:00:00,支出,商户消费,早餐店,豆浆,¥5.50,零钱,支付成功,111222333444555,,
        """
        let rows = try WeChatCSVParser.rows(fromText: text)
        let row = try #require(rows.first)
        #expect(row.transactionType == "商户消费")
        #expect(row.product == "豆浆")
        #expect(row.amount == Decimal(string: "5.50"))
        #expect(row.direction == .expense)
    }

    @Test("金额解析：千分位、无符号、非法值")
    func parsesAmounts() {
        #expect(WeChatCSVParser.parseAmount("¥1,234.56") == Decimal(string: "1234.56"))
        #expect(WeChatCSVParser.parseAmount("45") == Decimal(string: "45"))
        #expect(WeChatCSVParser.parseAmount("¥1000.00") == Decimal(string: "1000.00"))
        #expect(WeChatCSVParser.parseAmount("/") == nil)
        #expect(WeChatCSVParser.parseAmount("") == nil)
    }

    @Test("缺少表头时报错")
    func requiresHeader() {
        #expect(throws: (any Error).self) {
            try WeChatCSVParser.rows(fromText: "没有表头的文件\n内容")
        }
    }
}

@Suite("PDF 表格重建")
struct BillReconstructionTests {
    private typealias Reconstructor = BillTableReconstructor

    private var headerTokens: [BillTextToken] {
        [
            BillTextToken(text: "交易时间", x: 0.032, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "交易类型", x: 0.145, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "交易对方", x: 0.227, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "商品", x: 0.293, y: 0.546, width: 0.03, height: 0.012),
            BillTextToken(text: "收/支", x: 0.352, y: 0.552, width: 0.03, height: 0.010),
            BillTextToken(text: "金额", x: 0.390, y: 0.552, width: 0.03, height: 0.010),
            BillTextToken(text: "支付方式", x: 0.447, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "当前状态", x: 0.509, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "交易单号", x: 0.579, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "商户单号", x: 0.663, y: 0.546, width: 0.05, height: 0.012),
            BillTextToken(text: "备注", x: 0.735, y: 0.546, width: 0.03, height: 0.012),
        ]
    }

    /// 按微信账单模板的列横坐标放置文本块。
    private func tokens(_ entries: [(column: Int, text: String)], y: Double) -> [BillTextToken] {
        // 每列的中心位置，块宽取窄一些，保证落在对应列内。
        let columns: [Double] = [0.045, 0.137, 0.223, 0.291, 0.343, 0.389, 0.445, 0.511, 0.582, 0.660, 0.770]
        return entries.enumerated().map { offset, entry in
            BillTextToken(
                text: entry.text,
                x: columns[min(entry.column, columns.count - 1)] - 0.006,
                y: y + Double(offset) * 0.0001,
                width: 0.012,
                height: 0.012
            )
        }
    }

    private var boundaries: [Double] { Reconstructor.fallbackColumnBoundaries }

    @Test("按行归集文本并解析各列")
    func buildsRowsFromTokens() {
        var all = headerTokens
        all += tokens([
            (0, "2024/1/15 12:34:56"), (1, "商户消费"), (2, "某餐厅"), (3, "午餐"),
            (4, "支出"), (5, "¥25.80"), (6, "零钱"), (7, "支付成功"),
            (8, "4200001234"), (9, "MM2024"), (10, ""),
        ], y: 0.52)
        all += tokens([
            (0, "2024/1/16 09:00:00"), (1, "转账"), (2, "张三"), (3, "租金"),
            (4, "收入"), (5, "¥100.00"), (6, "零钱"), (7, "已存入零钱"),
            (8, "4200005678"), (9, ""), (10, ""),
        ], y: 0.49)

        let rows = Reconstructor.rows(from: all, columnBoundaries: boundaries)
        #expect(rows.count == 2)

        let first = rows[0]
        #expect(first.transactionType == "商户消费")
        #expect(first.counterparty == "某餐厅")
        #expect(first.amount == Decimal(string: "25.80"))
        #expect(first.direction == .expense)
        #expect(first.paymentMethod == "零钱")

        let second = rows[1]
        #expect(second.direction == .income)
        #expect(second.amount == Decimal(string: "100.00"))
        #expect(second.status == "已存入零钱")
    }

    @Test("OCR 把「支出 ¥20.00 零钱」并成一格时仍能拆出方向、金额与支付方式")
    func repairsMergedCells() {
        var all = headerTokens
        all += tokens([
            (0, "2024/1/17 11:38:13"), (1, "群收款"), (2, "张三"), (3, "群收款"),
            (6, "支出 ¥20.00 零钱"),
        ], y: 0.52)

        let rows = Reconstructor.rows(from: all, columnBoundaries: boundaries)
        let row = rows[0]
        #expect(row.amount == Decimal(string: "20.00"))
        #expect(row.direction == .expense)
        #expect(row.paymentMethod == "零钱")
        #expect(row.isValid)
    }

    @Test("银行卡号不会被当成金额剥离")
    func keepsBankCardDigits() {
        var all = headerTokens
        all += tokens([
            (0, "2024/1/18 09:00:00"), (1, "转账"), (2, "张三"), (3, "房租"),
            (4, "支出"), (5, "¥100.00"), (6, "工商银行 (1234)"), (7, "支付成功"),
        ], y: 0.52)

        let rows = Reconstructor.rows(from: all, columnBoundaries: boundaries)
        #expect(rows[0].paymentMethod.contains("1234"))
    }

    @Test("交易类型与交易对方被并成一格时按已知类型拆分")
    func splitsMergedTypeAndCounterparty() {
        var all = headerTokens
        all += tokens([
            (0, "2024/1/19 09:00:00"), (1, "转账到银行卡 赵五"), (3, "尾款"),
            (4, "支出"), (5, "¥500.00"), (6, "零钱"), (7, "支付成功"),
        ], y: 0.52)

        let rows = Reconstructor.rows(from: all, columnBoundaries: boundaries)
        #expect(rows[0].transactionType == "转账到银行卡")
        #expect(rows[0].counterparty == "赵五")
    }

    @Test("日期与金额解析")
    func parsesDateAndAmount() {
        #expect(Reconstructor.parseDate("2024/1/15 12:34:56") != nil)
        #expect(Reconstructor.parseDate("2024-01-15 12:34:56") != nil)
        #expect(Reconstructor.parseDate("随便什么") == nil)
        #expect(Reconstructor.amount(in: "¥1,234.56") == Decimal(string: "1234.56"))
        #expect(Reconstructor.amount(in: "¥1000.00") == Decimal(string: "1000.00"))
        // 交易单号这类长数字不能被当成金额。
        #expect(Reconstructor.amount(in: "420000123420240115000000001") == nil)
    }

    @Test("网格线检测能识别表格竖线")
    func detectsGridLines() {
        let width = 200
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height)
        for x in [20, 80, 140, 190] {
            for row in 100..<300 {
                pixels[row * width + x] = 200
            }
        }
        let lines = BillGridDetector.verticalLines(
            pixels: pixels,
            width: width,
            height: height,
            region: 0.25...0.75
        )
        #expect(lines.count == 4)
        #expect(abs(lines[0] - 0.1) < 0.02)
    }
}
