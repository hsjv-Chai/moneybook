import Foundation

/// 界面统一使用的金额与日期格式化工具（人民币 + 简体中文）。
enum Formatters {
    static let currencyCode = "CNY"
    static let locale = Locale(identifier: "zh_CN")

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    /// ¥1,234.56
    static func currency(_ value: Decimal) -> String {
        value.formatted(.currency(code: currencyCode).locale(locale))
    }

    /// 带方向的展示金额：支出 −¥12.00、收入 +¥12.00、转账 ¥12.00。
    static func signedCurrency(_ value: Decimal, kind: EntryKind) -> String {
        let magnitude = currency(value.absolute)
        switch kind {
        case .expense: return "−\(magnitude)"
        case .income: return "+\(magnitude)"
        case .transfer: return magnitude
        }
    }

    /// 1,234.56（不带货币符号，用于输入框与紧凑场景）。
    static func amount(_ value: Decimal) -> String {
        value.roundedToCents().formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// 解析用户输入的金额，容忍货币符号、千分位与空白。
    static func parseAmount(_ text: String) -> Decimal? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["¥", ",", "，", " ", "\u{00A0}"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        guard !cleaned.isEmpty else { return nil }
        guard let value = Decimal(string: cleaned, locale: posixLocale) else { return nil }
        return value.roundedToCents()
    }

    /// 2026年9月
    static func monthTitle(_ date: Date) -> String {
        formatter("yyyy年M月").string(from: date)
    }

    /// 9月
    static func shortMonth(_ date: Date) -> String {
        formatter("M月").string(from: date)
    }

    /// 9月12日
    static func dayTitle(_ date: Date) -> String {
        formatter("M月d日").string(from: date)
    }

    /// 2026年9月12日
    static func fullDate(_ date: Date) -> String {
        formatter("yyyy年M月d日").string(from: date)
    }

    /// 2026年9月12日 星期四
    static func fullDateWithWeekday(_ date: Date) -> String {
        formatter("yyyy年M月d日 EEEE").string(from: date)
    }

    /// 2026-09-12
    static func isoDate(_ date: Date) -> String {
        formatter("yyyy-MM-dd").string(from: date)
    }

    /// 2026年9月1日 – 2026年9月30日
    static func rangeTitle(_ interval: DateInterval) -> String {
        let inclusiveEnd = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(fullDate(interval.start)) – \(fullDate(inclusiveEnd))"
    }
}
