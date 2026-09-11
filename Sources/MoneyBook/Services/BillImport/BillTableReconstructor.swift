import Foundation

/// OCR 识别出的一段文字及其归一化坐标（原点在左下角，与 Vision 一致）。
struct BillTextToken: Hashable, Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

/// 把 OCR 文本块重建成微信账单的表格行。
///
/// 之所以不直接按列取值：OCR 会把相邻单元格合并成一段文字（例如「支出 ¥100.00」），
/// 所以这里先用几何位置把文字分配到行，再用语义规则修正被合并的单元格。
enum BillTableReconstructor {
    /// 微信账单列表的标准列。
    static let standardColumns = [
        "交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)",
        "支付方式", "当前状态", "交易单号", "商户单号", "备注",
    ]

    /// 网格线检测失败时的兜底列边界（按微信账单模板估算）。
    static let fallbackColumnBoundaries: [Double] = [
        0.000, 0.088, 0.186, 0.260, 0.322, 0.365, 0.413, 0.478, 0.544, 0.621, 0.699, 1.001,
    ]

    private static let datePattern = try! NSRegularExpression(
        pattern: #"(\d{4})[/-](\d{1,2})[/-](\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})"#
    )
    private static let amountPattern = try! NSRegularExpression(
        pattern: #"[¥￥]?\s*(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?"#
    )

    /// 微信账单的交易类型取值，用于在 OCR 把「类型 + 对方」并成一格时拆开。
    private static let knownTransactionTypes = [
        "二维码收付款", "扫二维码付款", "转账到银行卡", "零钱通转出", "零钱通转入",
        "理财通购买", "理财通赎回", "信用卡自动还款", "商户消费", "商家转账",
        "二维码收款", "信用卡还款", "零钱充值", "零钱提现", "生活缴费",
        "手机充值", "分付还款", "微信红包", "群收款", "群红包",
        "转账", "提现", "充值", "退款",
    ].sorted { $0.count > $1.count }

    /// 主入口：把一页 OCR 结果重建成账单行。
    static func rows(from tokens: [BillTextToken], columnBoundaries: [Double]?) -> [BillRow] {
        let boundaries = normalized(boundaries: columnBoundaries) ?? deriveColumnBoundaries(from: tokens)
        guard boundaries.count >= 2 else { return [] }

        let headerTokens = tokens.filter { isHeaderToken($0) }
        let headerBottom = headerTokens.map(\.minY).min()

        // 表头以下的部分才是明细数据。
        let dataTokens: [BillTextToken]
        if let headerBottom {
            dataTokens = tokens.filter { $0.maxY <= headerBottom + 0.004 }
        } else {
            dataTokens = tokens
        }
        guard !dataTokens.isEmpty else { return [] }

        let dateTokens = dataTokens.filter { isDateToken($0, boundaries: boundaries) }
        guard !dateTokens.isEmpty else { return [] }

        let anchors = dateTokens.sorted { $0.centerY > $1.centerY }
        let bands = rowBands(anchors: anchors, headerBottom: headerBottom)

        var cells: [[String]] = Array(
            repeating: Array(repeating: "", count: boundaries.count - 1),
            count: anchors.count
        )

        // 日期本身先落位。
        for (index, token) in anchors.enumerated() {
            cells[index][0] = token.text
        }

        for token in dataTokens where !isDateToken(token, boundaries: boundaries) {
            guard let rowIndex = bandIndex(for: token, bands: bands) else { continue }
            guard let column = columnIndex(for: token, boundaries: boundaries) else { continue }
            append(token, to: &cells[rowIndex], column: column)
        }

        return cells.enumerated().map { index, row in
            makeRow(from: row, sourceLine: index + 1)
        }
    }

    // MARK: - 行/列定位

    private static func rowBands(
        anchors: [BillTextToken],
        headerBottom: Double?
    ) -> [(top: Double, bottom: Double)] {
        var bands: [(top: Double, bottom: Double)] = []
        let centers = anchors.map(\.centerY)
        let top = headerBottom ?? (centers[0] + 0.02)

        for (index, center) in centers.enumerated() {
            let bandTop: Double
            if index == 0 {
                bandTop = top
            } else {
                bandTop = (centers[index - 1] + center) / 2
            }

            let bandBottom: Double
            if index == centers.count - 1 {
                bandBottom = center - 0.03
            } else {
                bandBottom = (center + centers[index + 1]) / 2
            }
            bands.append((top: bandTop, bottom: bandBottom))
        }
        return bands
    }

    private static func bandIndex(
        for token: BillTextToken,
        bands: [(top: Double, bottom: Double)]
    ) -> Int? {
        if let exact = bands.firstIndex(where: { token.centerY <= $0.top && token.centerY > $0.bottom }) {
            return exact
        }
        // 跨行边界（单元格换行）时取最近的锚点。
        return bands.enumerated()
            .min { abs($0.element.top - token.centerY) < abs($1.element.top - token.centerY) }?
            .offset
    }

    private static func columnIndex(for token: BillTextToken, boundaries: [Double]) -> Int? {
        var best: (index: Int, overlap: Double)?
        for index in 0..<(boundaries.count - 1) {
            let left = boundaries[index]
            let right = boundaries[index + 1]
            let overlap = min(token.maxX, right) - max(token.minX, left)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (index, overlap)
            }
        }
        if let best { return best.index }

        // 完全落在边界之外时按中心点就近归列。
        return boundaries.enumerated()
            .min { abs($0.element - token.centerX) < abs($1.element - token.centerX) }?
            .offset
            .clamped(to: 0...(boundaries.count - 2))
    }

    private static func append(_ token: BillTextToken, to row: inout [String], column: Int) {
        guard row.indices.contains(column) else { return }
        let existing = row[column]
        if existing.isEmpty {
            row[column] = token.text
        } else if existing.hasSuffix(token.text) {
            // 同一单元格重复识别，忽略。
        } else {
            row[column] = existing + " " + token.text
        }
    }

    // MARK: - 单元格 → 账单行

    private static func makeRow(from cells: [String], sourceLine: Int) -> BillRow {
        var row = BillRow(sourceLine: sourceLine)
        row.rawDate = cell(cells, 0)
        row.transactionType = cell(cells, 1)
        row.counterparty = cell(cells, 2)
        row.product = cell(cells, 3)
        row.paymentMethod = cell(cells, 6)
        row.status = cell(cells, 7)
        row.transactionID = identifierText(cell(cells, 8))
        row.merchantID = identifierText(cell(cells, 9))
        row.remark = cell(cells, 10)

        // 收/支与金额常被合并成一段文字，这里从合并文本里拆出来。
        let directionCell = cell(cells, 4)
        let amountCell = cell(cells, 5)
        let combined = [directionCell, amountCell].filter { !$0.isEmpty }.joined(separator: " ")

        row.directionText = directionText(in: combined)
        row.amount = amount(in: amountCell) ?? amount(in: combined)
        row.date = parseDate(row.rawDate) ?? parseDate(combined)

        // OCR 可能把「收/支 + 金额 + 支付方式」并成一个文本块，落到相邻列里，
        // 这时在整行（除日期、单号、备注外）范围内再找一次。
        if row.directionText.isEmpty || row.amount == nil {
            let searchable = (1...7).map { cell(cells, $0) }.filter { !$0.isEmpty }.joined(separator: " ")
            if row.directionText.isEmpty {
                row.directionText = directionText(in: searchable)
            }
            if row.amount == nil {
                row.amount = amount(in: searchable)
            }
        }

        // 单号被合并进同一单元格时，按数字串顺序拆分。
        if row.transactionID.isEmpty || row.merchantID.isEmpty {
            let runs = digitRuns([cell(cells, 8), cell(cells, 9)].joined(separator: " "))
            if row.transactionID.isEmpty { row.transactionID = runs.first ?? "" }
            if row.merchantID.isEmpty, runs.count > 1 { row.merchantID = runs[1] }
        }

        // 状态被并进支付方式单元格时拆出来。
        if row.status.isEmpty {
            let split = splitStatus(from: row.paymentMethod)
            row.paymentMethod = split.paymentMethod
            row.status = split.status
        }

        // 支付方式一格里可能残留「支出 ¥20.00 零钱」这类合并文本，剥离已知字段。
        row.paymentMethod = stripKnownFields(from: row.paymentMethod)

        splitTransactionType(&row)

        row.issues = validate(row)
        return row
    }

    /// 去掉误并进某一格的收/支与金额文字，剩下的才是真正的支付方式。
    private static func stripKnownFields(from text: String) -> String {
        // 只有确实混入了收/支或货币符号时才剥离，
        // 否则「工商银行(1234)」这类名称会被当成金额删掉。
        guard text.contains("收入") || text.contains("支出") || text.contains("¥") || text.contains("￥") else {
            return text
        }

        var result = text
        for token in ["收入", "支出"] where result.contains(token) {
            result = result.replacingOccurrences(of: token, with: " ")
        }
        if let matched = currencyAmountPattern.firstMatch(in: result),
           let range = Range(matched.range(at: 0), in: result) {
            result = result.replacingCharacters(in: range, with: " ")
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 仅匹配带货币符号或带小数的金额，用于从合并单元格里剥离。
    private static let currencyAmountPattern = try! NSRegularExpression(
        pattern: #"([¥￥]\s*\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?)|(\d+\.\d{1,2})"#
    )

    /// 交易类型与交易对方被识别成一个文本块时，按已知类型前缀拆分。
    static func splitTransactionType(_ row: inout BillRow) {
        if let type = knownTransactionTypes.first(where: { row.transactionType.hasPrefix($0) }),
           row.transactionType.count > type.count {
            let remainder = String(row.transactionType.dropFirst(type.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            row.transactionType = type
            if row.counterparty.isEmpty, !remainder.isEmpty {
                row.counterparty = remainder
            }
            return
        }

        guard row.transactionType.isEmpty else { return }
        if let type = knownTransactionTypes.first(where: { row.counterparty.hasPrefix($0) }),
           row.counterparty.count > type.count {
            let remainder = String(row.counterparty.dropFirst(type.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            row.transactionType = type
            row.counterparty = remainder
        }
    }

    private static func validate(_ row: BillRow) -> [String] {
        var issues: [String] = []
        if row.date == nil { issues.append("日期无法识别") }
        if row.amount == nil { issues.append("金额无法识别") }
        if row.transactionType.isEmpty && row.counterparty.isEmpty && row.product.isEmpty {
            issues.append("缺少交易信息")
        }
        return issues
    }

    // MARK: - 文本解析

    private static func cell(_ cells: [String], _ index: Int) -> String {
        guard cells.indices.contains(index) else { return "" }
        return cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDate(_ text: String) -> Date? {
        guard let match = datePattern.firstMatch(in: text) else { return nil }

        func group(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return Int(text[swiftRange])
        }

        guard
            let year = group(1), let month = group(2), let day = group(3),
            let hour = group(4), let minute = group(5), let second = group(6)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)
    }

    static func amount(in text: String) -> Decimal? {
        guard !text.isEmpty else { return nil }
        let matches = amountPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range(at: 0), in: text) else { continue }
            var raw = String(text[range])
            for token in ["¥", "￥", ",", " ", "\u{00A0}"] {
                raw = raw.replacingOccurrences(of: token, with: "")
            }
            guard let value = Decimal(string: raw), value > 0 else { continue }
            // 排除把「1000395010120」这种单号误当金额的情况。
            if value >= 1_000_000 { continue }
            return value.roundedToCents()
        }
        return nil
    }

    static func directionText(in text: String) -> String {
        if text.contains("支出") { return "支出" }
        if text.contains("收入") { return "收入" }
        if text.contains("/") { return "/" }
        return ""
    }

    static func digits(_ text: String) -> String {
        text.filter { $0.isNumber }
    }

    /// 单号可能是纯数字也可能带字母（如 MM20240115001），只去掉空白与标点。
    static func identifierText(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }
    }

    static func digitRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.filter { $0.count >= 4 }
    }

    static func splitStatus(from paymentCell: String) -> (paymentMethod: String, status: String) {
        let statusKeywords = [
            "支付成功", "已存入零钱", "已转账", "提现已到账", "已到账", "已收钱",
            "朋友已收钱", "已退款", "已全额退款", "对方已退还", "已退还", "已撤销",
            "交易关闭", "已关闭", "支付失败", "已失败", "等待确认收货", "已确认收货",
        ]
        for keyword in statusKeywords where paymentCell.contains(keyword) {
            let method = paymentCell.replacingOccurrences(of: keyword, with: "")
                .trimmingCharacters(in: .whitespaces)
            return (method, keyword)
        }
        return (paymentCell, "")
    }

    private static func isHeaderToken(_ token: BillTextToken) -> Bool {
        let text = token.text
        return text.contains("交易时间") || text.contains("交易类型") || text.contains("商户单号")
    }

    private static func isDateToken(_ token: BillTextToken, boundaries: [Double]) -> Bool {
        guard token.centerX < boundaries[min(1, boundaries.count - 1)] + 0.05 else { return false }
        return datePattern.firstMatch(in: token.text) != nil
    }

    private static func normalized(boundaries: [Double]?) -> [Double]? {
        guard let boundaries, boundaries.count >= 3 else { return nil }
        let sorted = boundaries.sorted()
        guard sorted.first! <= 0.05, sorted.last! >= 0.6 else { return nil }
        var result = sorted
        result[0] = 0
        result[result.count - 1] = 1.001
        return result
    }

    /// 没有网格线时，用文字块的横坐标聚类推算列边界。
    static func deriveColumnBoundaries(from tokens: [BillTextToken]) -> [Double] {
        let origins = tokens.map(\.minX).sorted()
        guard origins.count > BillTableReconstructor.standardColumns.count else {
            return fallbackColumnBoundaries
        }

        var clusters: [[Double]] = []
        for origin in origins {
            if var last = clusters.last, let reference = last.last, origin - reference < 0.02 {
                last.append(origin)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([origin])
            }
        }

        let centers = clusters.map { $0.reduce(0, +) / Double($0.count) }.sorted()
        guard centers.count >= BillTableReconstructor.standardColumns.count else {
            return fallbackColumnBoundaries
        }

        // 文字块可能被合并导致列数偏少，取最接近标准列数的均匀子集。
        let target = BillTableReconstructor.standardColumns.count
        let picked: [Double]
        if centers.count == target {
            picked = centers
        } else {
            picked = (0..<target).map { index in
                centers[Int((Double(index) / Double(target - 1)) * Double(centers.count - 1)).clamped(to: 0...(centers.count - 1))]
            }
        }

        var boundaries: [Double] = [0]
        for index in 1..<picked.count {
            boundaries.append((picked[index - 1] + picked[index]) / 2)
        }
        boundaries.append(1.001)
        return boundaries
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension NSRegularExpression {
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
