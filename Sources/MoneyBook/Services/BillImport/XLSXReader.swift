import Foundation

/// 读取 xlsx 的第一张工作表，把单元格转成字符串矩阵。
///
/// 只实现微信账单用得到的部分：共享字符串、内联字符串、数值、日期（按样式判断）。
enum XLSXReader {
    enum ReaderError: LocalizedError {
        case missingSheet
        case malformedSheet

        var errorDescription: String? {
            switch self {
            case .missingSheet: "xlsx 里没有找到工作表。"
            case .malformedSheet: "xlsx 工作表内容无法解析。"
            }
        }
    }

    /// 微信账单里所有时间都是 UTC+08:00，序列号按这个时区还原成文本。
    private static let billTimeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current

    static func firstSheetRows(from data: Data) throws -> [[String]] {
        let archive = try ZIPArchive(data: data)

        guard let sheetName = sheetEntryName(in: archive) else { throw ReaderError.missingSheet }
        guard let sheetData = try archive.data(for: sheetName) else { throw ReaderError.missingSheet }

        let sharedStrings = try loadSharedStrings(archive)
        let dateStyles = try loadDateStyles(archive)
        let uses1904 = loadUses1904Epoch(archive)

        return try parseSheet(
            sheetData,
            sharedStrings: sharedStrings,
            dateStyleIndexes: dateStyles,
            uses1904Epoch: uses1904
        )
    }

    private static func sheetEntryName(in archive: ZIPArchive) -> String? {
        if archive.entryNames.contains("xl/worksheets/sheet1.xml") {
            return "xl/worksheets/sheet1.xml"
        }
        return archive.entryNames
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
            .first
    }

    // MARK: - 共享字符串

    private static func loadSharedStrings(_ archive: ZIPArchive) throws -> [String] {
        guard let data = try archive.data(for: "xl/sharedStrings.xml") else { return [] }
        let delegate = SharedStringsDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return delegate.strings }
        return delegate.strings
    }

    private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current: String?
        private var insideText = false
        private var insidePhonetic = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "si":
                current = ""
            case "t":
                insideText = true
            case "rPh":
                insidePhonetic = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideText, !insidePhonetic, current != nil else { return }
            current?.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch elementName {
            case "t":
                insideText = false
            case "rPh":
                insidePhonetic = false
            case "si":
                strings.append(current ?? "")
                current = nil
            default:
                break
            }
        }
    }

    // MARK: - 样式（判断哪些格式是日期）

    private static func loadDateStyles(_ archive: ZIPArchive) throws -> Set<Int> {
        guard let data = try archive.data(for: "xl/styles.xml") else { return [] }
        let delegate = StylesDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.dateStyleIndexes
    }

    final class StylesDelegate: NSObject, XMLParserDelegate {
        private var customDateFormats: Set<Int> = []
        private var cellFormatIDs: [Int] = []
        private var insideCellFormats = false

        var dateStyleIndexes: Set<Int> {
            Set(cellFormatIDs.enumerated().compactMap { index, formatID in
                isDate(formatID: formatID) ? index : nil
            })
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "numFmt":
                if let raw = attributes["numFmtId"], let id = Int(raw),
                   let code = attributes["formatCode"], StylesDelegate.looksLikeDateFormat(code) {
                    customDateFormats.insert(id)
                }
            case "cellXfs":
                insideCellFormats = true
            case "xf":
                if insideCellFormats {
                    let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
                    cellFormatIDs.append(id)
                }
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if elementName == "cellXfs" { insideCellFormats = false }
        }

        private func isDate(formatID: Int) -> Bool {
            if customDateFormats.contains(formatID) { return true }
            // 内置日期与时间格式（含东亚日期格式）。
            switch formatID {
            case 14...22, 27...36, 45...47, 50...58: return true
            default: return false
            }
        }

        /// 去掉引号里的字面量与 [..] 修饰段后，看是否出现日期时间占位符。
        static func looksLikeDateFormat(_ code: String) -> Bool {
            var stripped = ""
            var insideQuotes = false
            var insideBrackets = false

            for character in code {
                if insideQuotes {
                    if character == "\"" { insideQuotes = false }
                    continue
                }
                if insideBrackets {
                    if character == "]" { insideBrackets = false }
                    continue
                }
                switch character {
                case "\"": insideQuotes = true
                case "[": insideBrackets = true
                case "\\": continue
                default: stripped.append(character)
                }
            }

            let lowercased = stripped.lowercased()
            return ["y", "d", "h", "s"].contains { lowercased.contains($0) }
                || lowercased.contains("m")
        }
    }

    private static func loadUses1904Epoch(_ archive: ZIPArchive) -> Bool {
        guard let data = try? archive.data(for: "xl/workbook.xml") else { return false }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("date1904=\"1\"") || text.contains("date1904=\"true\"")
    }

    // MARK: - 工作表

    static func parseSheet(
        _ data: Data,
        sharedStrings: [String],
        dateStyleIndexes: Set<Int>,
        uses1904Epoch: Bool = false
    ) throws -> [[String]] {
        let delegate = SheetDelegate(
            sharedStrings: sharedStrings,
            dateStyleIndexes: dateStyleIndexes,
            uses1904Epoch: uses1904Epoch
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.rows.isEmpty else { throw ReaderError.malformedSheet }
        return delegate.rows
    }

    final class SheetDelegate: NSObject, XMLParserDelegate {
        private let sharedStrings: [String]
        private let dateStyleIndexes: Set<Int>
        private let uses1904Epoch: Bool

        private var currentRow: [String] = []
        private var currentRowIndex = 0
        private var currentColumn = 0
        private var currentType: String?
        private var currentStyle: Int?
        private var rawValue = ""
        private var inlineValue = ""
        private var insideValue = false
        private var insideInlineText = false

        private(set) var rows: [[String]] = []

        init(sharedStrings: [String], dateStyleIndexes: Set<Int>, uses1904Epoch: Bool) {
            self.sharedStrings = sharedStrings
            self.dateStyleIndexes = dateStyleIndexes
            self.uses1904Epoch = uses1904Epoch
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "row":
                currentRow = []
                currentRowIndex = attributes["r"].flatMap(Int.init) ?? (currentRowIndex + 1)
            case "c":
                currentType = attributes["t"]
                currentStyle = attributes["s"].flatMap(Int.init)
                currentColumn = XLSXReader.columnIndex(from: attributes["r"])
                rawValue = ""
                inlineValue = ""
            case "v":
                insideValue = true
            case "t":
                insideInlineText = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if insideValue { rawValue.append(string) }
            if insideInlineText { inlineValue.append(string) }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch elementName {
            case "v":
                insideValue = false
            case "t":
                insideInlineText = false
            case "c":
                storeCell()
            case "row":
                storeRow()
            default:
                break
            }
        }

        private func storeCell() {
            let value = resolveValue()
            while currentRow.count <= currentColumn { currentRow.append("") }
            currentRow[currentColumn] = value
        }

        private func resolveValue() -> String {
            switch currentType {
            case "s":
                guard let index = Int(rawValue), sharedStrings.indices.contains(index) else { return "" }
                return sharedStrings[index]
            case "inlineStr":
                return inlineValue
            case "str":
                return rawValue
            case "b":
                return rawValue == "1" ? "TRUE" : "FALSE"
            case "e":
                return ""
            default:
                if let style = currentStyle, dateStyleIndexes.contains(style),
                   let serial = Double(rawValue) {
                    return XLSXReader.formatSerialDate(serial, uses1904Epoch: uses1904Epoch)
                }
                return rawValue
            }
        }

        private func storeRow() {
            guard currentRowIndex > 0 else { return }
            while rows.count < currentRowIndex { rows.append([]) }
            rows[currentRowIndex - 1] = currentRow
        }
    }

    /// "AB12" → 27（0 基列号）。
    static func columnIndex(from reference: String?) -> Int {
        guard let reference else { return 0 }
        var index = 0
        var found = false
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
            found = true
        }
        return found ? index - 1 : 0
    }

    /// Excel 序列号 → "yyyy-MM-dd HH:mm:ss"（按账单声明的 UTC+08:00）。
    static func formatSerialDate(_ serial: Double, uses1904Epoch: Bool) -> String {
        // 1899-12-30 是 Excel 1900 日期系统的零点（含 1900 闰年兼容偏移），
        // 1904 系统则以 1904-01-01 为零点，两者相差 1462 天。
        let baseDays: Double = uses1904Epoch ? 25_569 - 1_462 : 25_569

        // 序列号表示的是「当地墙钟时间」，账单声明所有时间为 UTC+08:00，
        // 所以先按 UTC 还原墙钟，再减去 8 小时得到真实时刻，
        // 后面仍用同一时区格式化即可还原原始时间。
        let offset = Double(billTimeZone.secondsFromGMT(for: Date(timeIntervalSince1970: 0)))
        let date = Date(timeIntervalSince1970: (serial - baseDays) * 86_400 - offset)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = billTimeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
