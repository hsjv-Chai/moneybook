import Foundation

/// CSV / TXT 账单文本的解码与词法解析（微信与支付宝导出都是这种结构）。
enum CSVText {
    /// 微信是 UTF-8（带 BOM），支付宝导出多为 GB18030。
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) { return text }
        return String(data: data, encoding: .utf16)
    }

    static func records(from text: String) -> [[String]] {
        let delimiter: Character = looksTabSeparated(text) ? "\t" : ","
        return records(from: text, delimiter: delimiter)
    }

    private static func looksTabSeparated(_ text: String) -> Bool {
        guard let headerLine = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("交易时间") }) else {
            return false
        }
        return headerLine.filter { $0 == "\t" }.count > headerLine.filter { $0 == "," }.count
    }

    /// RFC4180 风格解析：支持引号包裹、字段内逗号与换行、CRLF。
    static func records(from text: String, delimiter: Character) -> [[String]] {
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
            } else if character == "\"" {
                insideQuotes = true
            } else if character == delimiter {
                endField()
            } else if character.isNewline {
                // 注意：Swift 里 "\r\n" 是单个 Character，必须用 isNewline 覆盖
                // \n、\r 与 CRLF 三种换行，否则 CRLF 行不会被切断。
                endRecord()
            } else {
                field.append(character)
            }

            index = text.index(after: index)
        }

        if !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        return records
    }
}
