import Foundation

/// 解析微信支付账单 CSV（官方「用于个人对账」导出的文件）。
enum WeChatCSVParser {
    static func parse(url: URL) throws -> (rows: [BillRow], summary: BillSummary?) {
        guard let data = try? Data(contentsOf: url) else { throw BillImportError.unreadableFile }
        guard let text = decode(data) else { throw BillImportError.unreadableFile }
        let delimiter: Character = looksTabSeparated(text) ? "\t" : ","
        let records = csvRecords(from: text, delimiter: delimiter)
        let rows = try rows(fromRecords: records)
        guard !rows.isEmpty else { throw BillImportError.noRecordsFound }

        let headerIndex = records.firstIndex(where: isHeaderRecord) ?? 0
        let preamble = records[..<headerIndex].map { $0.joined(separator: " ") }
        return (rows, BillSummaryParser.parse(lines: preamble))
    }

    static func rows(fromText text: String) throws -> [BillRow] {
        let delimiter: Character = looksTabSeparated(text) ? "\t" : ","
        let records = csvRecords(from: text, delimiter: delimiter)
        return try rows(fromRecords: records)
    }

    /// 微信账单前 16 行是说明信息，真正的明细从「交易时间」表头开始。
    static func rows(fromRecords records: [[String]]) throws -> [BillRow] {
        guard let headerIndex = records.firstIndex(where: isHeaderRecord) else {
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

    // MARK: - 解码

    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        // 早期导出的账单可能是 GB18030 编码。
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) { return text }
        return String(data: data, encoding: .utf16)
    }

    private static func looksTabSeparated(_ text: String) -> Bool {
        guard let headerLine = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("交易时间") }) else {
            return false
        }
        return headerLine.filter { $0 == "\t" }.count > headerLine.filter { $0 == "," }.count
    }

    // MARK: - CSV 词法

    static func csvRecords(from text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex

        func endField() {
            fields.append(field)
            field = ""
        }

        func endRecord() {
            endField()
            if fields.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                records.append(fields)
            }
            fields = []
        }

        while index < text.endIndex {
            let character = text[index]

            if insideQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        insideQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    insideQuotes = true
                case delimiter:
                    endField()
                case "\r":
                    if text.index(after: index) < text.endIndex, text[text.index(after: index)] == "\n" {
                        index = text.index(after: index)
                    }
                    endRecord()
                case "\n":
                    endRecord()
                default:
                    field.append(character)
                }
            }

            index = text.index(after: index)
        }

        if !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        return records
    }

    // MARK: - 表头与字段

    private static func isHeaderRecord(_ record: [String]) -> Bool {
        record.contains { normalizeHeader($0) == "交易时间" }
    }

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

    /// 金额可能是「¥45.00」「45.00」「45」，也可能带千分位。
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
