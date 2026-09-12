import Foundation

/// 把「行 × 列」的原始表格（来自 CSV 或 xlsx）解析成微信账单行。
///
/// 两种导出格式的列名与列顺序一致，所以这里只按列名取值，两处复用同一套规则。
enum WeChatBillRecords {
    static func headerIndex(in records: [[String]]) -> Int? {
        records.firstIndex { record in
            record.contains { normalizeHeader($0) == "交易时间" }
        }
    }

    /// 明细行：表头之后的所有非空行。
    static func rows(from records: [[String]]) throws -> [BillRow] {
        guard let headerIndex = headerIndex(in: records) else {
            throw BillImportError.noRecordsFound
        }

        let header = records[headerIndex].map(normalizeHeader)
        let columnMap = makeColumnMap(header: header)
        let dataRecords = records[(headerIndex + 1)...]

        var rows: [BillRow] = []
        for (offset, record) in dataRecords.enumerated() {
            guard record.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                continue
            }
            var row = makeRow(record: record, columnMap: columnMap)
            row.sourceLine = offset + 1
            row.issues = issues(for: row)
            rows.append(row)
        }
        return rows
    }

    /// 账单头部的汇总信息（共 N 笔 / 收入 / 支出 / 中性交易）。
    static func summary(from records: [[String]]) -> BillSummary? {
        let headerIndex = headerIndex(in: records) ?? 0
        let preamble = records[..<headerIndex].map { $0.joined(separator: " ") }
        return BillSummaryParser.parse(lines: preamble)
    }

    // MARK: - 表头与字段

    private static func normalizeHeader(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private struct ColumnMap {
        var date = 0
        var transactionType = 1
        var counterparty = 2
        var product = 3
        var direction = 4
        var amount = 5
        var paymentMethod = 6
        var status = 7
        var transactionID = 8
        var merchantID = 9
        var remark = 10
    }

    private static func makeColumnMap(header: [String]) -> ColumnMap {
        var map = ColumnMap()
        for (index, name) in header.enumerated() {
            switch true {
            case name == "交易时间": map.date = index
            case name == "交易类型": map.transactionType = index
            case name == "交易对方": map.counterparty = index
            case name == "商品": map.product = index
            case name == "收/支" || name == "收支": map.direction = index
            case name.hasPrefix("金额"): map.amount = index
            case name == "支付方式": map.paymentMethod = index
            case name == "当前状态" || name == "交易状态": map.status = index
            case name == "交易单号": map.transactionID = index
            case name == "商户单号": map.merchantID = index
            case name == "备注": map.remark = index
            default: break
            }
        }
        return map
    }

    private static func makeRow(record: [String], columnMap: ColumnMap) -> BillRow {
        func value(_ index: Int) -> String {
            guard record.indices.contains(index) else { return "" }
            return record[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var row = BillRow(sourceLine: 0)
        row.rawDate = value(columnMap.date)
        row.date = BillTableReconstructor.parseDate(row.rawDate)
        row.transactionType = value(columnMap.transactionType)
        row.counterparty = value(columnMap.counterparty)
        row.product = value(columnMap.product)
        row.directionText = value(columnMap.direction)
        row.amount = parseAmount(value(columnMap.amount))
        row.paymentMethod = value(columnMap.paymentMethod)
        row.status = value(columnMap.status)
        row.transactionID = BillTableReconstructor.identifierText(value(columnMap.transactionID))
        row.merchantID = BillTableReconstructor.identifierText(value(columnMap.merchantID))
        row.remark = value(columnMap.remark)
        return row
    }

    /// 金额可能是「¥45.00」「45.00」「45」「1,234.56」，也可能带「元」。
    static func parseAmount(_ text: String) -> Decimal? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "/" else { return nil }
        for token in ["¥", "￥", ",", " ", "\u{00A0}", "元"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard let value = Decimal(string: cleaned), value > 0 else { return nil }
        return value.roundedToCents()
    }

    private static func issues(for row: BillRow) -> [String] {
        var issues: [String] = []
        if row.date == nil { issues.append("日期无法识别") }
        if row.amount == nil { issues.append("金额无法识别") }
        if row.direction == nil { issues.append("收支方向无法识别") }
        return issues
    }
}
