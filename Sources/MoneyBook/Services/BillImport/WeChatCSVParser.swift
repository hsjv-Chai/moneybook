import Foundation

/// 解析微信支付账单 CSV / TXT（官方「用于个人对账」导出的文件）。
///
/// 表格到账单行的映射与 xlsx 共用，见 `WeChatBillRecords`。
enum WeChatCSVParser {
    static func parse(url: URL) throws -> (rows: [BillRow], summary: BillSummary?) {
        guard let data = try? Data(contentsOf: url) else { throw BillImportError.unreadableFile }
        guard let text = decode(data) else { throw BillImportError.unreadableFile }

        let records = records(from: text)
        let rows = try WeChatBillRecords.rows(from: records)
        guard !rows.isEmpty else { throw BillImportError.noRecordsFound }
        return (rows, WeChatBillRecords.summary(from: records))
    }

    static func rows(fromText text: String) throws -> [BillRow] {
        try WeChatBillRecords.rows(from: records(from: text))
    }

    static func rows(fromRecords records: [[String]]) throws -> [BillRow] {
        try WeChatBillRecords.rows(from: records)
    }

    static func parseAmount(_ text: String) -> Decimal? {
        WeChatBillRecords.parseAmount(text)
    }

    static func records(from text: String) -> [[String]] {
        let delimiter: Character = looksTabSeparated(text) ? "\t" : ","
        return csvRecords(from: text, delimiter: delimiter)
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
}
