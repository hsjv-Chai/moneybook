import Foundation

/// 解析账单头部的汇总信息（共 13 笔记录 / 收入：4 笔 380.00 元 …）。
///
/// 这些数字来自微信自己，用来交叉校验逐行解析的结果：
/// OCR 偶尔会把 `¥10.00` 读成 `1000`，靠汇总能立刻发现金额对不上。
enum BillSummaryParser {
    private static let countPattern = try! NSRegularExpression(pattern: #"共\s*(\d+)\s*笔"#)
    private static let incomePattern = try! NSRegularExpression(
        pattern: #"收入[：:]\s*(\d+)\s*笔\s*([\d,]+(?:\.\d+)?)\s*元"#
    )
    private static let expensePattern = try! NSRegularExpression(
        pattern: #"支出[：:]\s*(\d+)\s*笔\s*([\d,]+(?:\.\d+)?)\s*元"#
    )
    private static let neutralPattern = try! NSRegularExpression(
        pattern: #"(?:中性交易|不计收支)[：:]\s*(\d+)\s*笔\s*([\d,]+(?:\.\d+)?)\s*元"#
    )

    static func parse(lines: [String]) -> BillSummary? {
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: " ")
        var summary = BillSummary()

        if let match = countPattern.firstMatch(in: text) {
            summary.totalCount = intValue(of: 1, in: text, match: match)
        }
        if let match = incomePattern.firstMatch(in: text) {
            summary.incomeCount = intValue(of: 1, in: text, match: match)
            summary.incomeTotal = decimalValue(of: 2, in: text, match: match)
        }
        if let match = expensePattern.firstMatch(in: text) {
            summary.expenseCount = intValue(of: 1, in: text, match: match)
            summary.expenseTotal = decimalValue(of: 2, in: text, match: match)
        }
        if let match = neutralPattern.firstMatch(in: text) {
            summary.neutralCount = intValue(of: 1, in: text, match: match)
            summary.neutralTotal = decimalValue(of: 2, in: text, match: match)
        }

        return summary.isEmpty ? nil : summary
    }

    /// 逐行汇总与账单自带汇总的比对结果。
    static func discrepancyWarnings(
        summary: BillSummary?,
        expense: Decimal,
        income: Decimal,
        neutral: Decimal,
        importedRowCount: Int
    ) -> [String] {
        guard let summary, !summary.isEmpty else { return [] }
        var warnings: [String] = []

        // 账单汇总按原始金额统计，优惠不计入差额判断，因此用「差值大于 0.01 且占比明显」来提示。
        if let expected = summary.expenseTotal, exceedsTolerance(actual: expense, expected: expected) {
            warnings.append(
                "支出合计 \(Formatters.currency(expense)) 与账单汇总 \(Formatters.currency(expected)) 不一致，请核对金额。"
            )
        }
        if let expected = summary.incomeTotal, exceedsTolerance(actual: income, expected: expected) {
            warnings.append(
                "收入合计 \(Formatters.currency(income)) 与账单汇总 \(Formatters.currency(expected)) 不一致，请核对金额。"
            )
        }
        if let expected = summary.neutralTotal, exceedsTolerance(actual: neutral, expected: expected) {
            warnings.append(
                "中性交易合计 \(Formatters.currency(neutral)) 与账单汇总 \(Formatters.currency(expected)) 不一致，请核对金额。"
            )
        }
        if let expected = summary.totalCount, expected != importedRowCount {
            warnings.append("账单标注 \(expected) 笔，本次解析出 \(importedRowCount) 笔。")
        }
        return warnings
    }

    /// 账单汇总按原始金额统计，优惠金额会造成小额差异；
    /// 只有超过 1%（且不低于 1 元）才提示，避免误报。
    private static func exceedsTolerance(actual: Decimal, expected: Decimal) -> Bool {
        let difference = abs((actual - expected).doubleValue)
        let threshold = max(1.0, abs(expected.doubleValue) * 0.01)
        return difference > threshold
    }

    private static func intValue(of group: Int, in text: String, match: NSTextCheckingResult) -> Int? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return Int(text[range])
    }

    private static func decimalValue(of group: Int, in text: String, match: NSTextCheckingResult) -> Decimal? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        let raw = text[range].replacingOccurrences(of: ",", with: "")
        return Decimal(string: raw)
    }
}
