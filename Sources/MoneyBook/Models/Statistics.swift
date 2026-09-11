import Foundation

/// 时间范围预设。
enum DateRangePreset: String, CaseIterable, Identifiable, Sendable {
    case thisMonth
    case lastMonth
    case lastThreeMonths
    case thisYear
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth: "本月"
        case .lastMonth: "上月"
        case .lastThreeMonths: "近三个月"
        case .thisYear: "今年"
        case .custom: "自定义"
        }
    }

    static var selectable: [DateRangePreset] { [.thisMonth, .lastMonth, .lastThreeMonths, .thisYear, .custom] }

    /// 计算时间区间；`.custom` 返回 nil，由调用方提供自定义区间。
    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)
        case .lastMonth:
            guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .month, for: lastMonth)
        case .lastThreeMonths:
            guard
                let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
                let start = calendar.date(byAdding: .month, value: -2, to: monthStart),
                let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            else { return nil }
            return DateInterval(start: start, end: end)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now)
        case .custom:
            return nil
        }
    }
}

/// 一个自然月的收支合计。
struct MonthlyTotal: Identifiable, Hashable, Sendable {
    let month: Date
    let income: Decimal
    let expense: Decimal

    var id: Date { month }
    var net: Decimal { income - expense }
}

/// 分类维度合计。
struct CategoryTotal: Identifiable, Hashable, Sendable {
    let categoryID: UUID
    let name: String
    let symbolName: String
    let colorHex: String
    let amount: Decimal

    var id: UUID { categoryID }
}

/// 账户维度合计。
struct AccountTotal: Identifiable, Hashable, Sendable {
    let accountID: UUID
    let name: String
    let symbolName: String
    let colorHex: String
    let balance: Decimal
    let isArchived: Bool

    var id: UUID { accountID }
}

/// 一段时间的收支合计。
struct PeriodTotals: Hashable, Sendable {
    let income: Decimal
    let expense: Decimal

    static let zero = PeriodTotals(income: .zero, expense: .zero)
    var net: Decimal { income - expense }
}

/// 流水列表的筛选条件。
struct EntryFilter: Equatable, Sendable {
    var range: DateInterval?
    var accountID: UUID?
    var categoryID: UUID?
    var kind: EntryKind?
    var searchText: String = ""

    var isActive: Bool {
        accountID != nil || categoryID != nil || kind != nil || !trimmedSearchText.isEmpty
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(_ entry: Entry) -> Bool {
        if let range, !range.contains(entry.date) { return false }

        if let accountID {
            let inSource = entry.account?.uuid == accountID
            let inDestination = entry.toAccount?.uuid == accountID
            if !inSource && !inDestination { return false }
        }

        if let categoryID, entry.category?.uuid != categoryID { return false }
        if let kind, entry.kind != kind { return false }

        let keyword = trimmedSearchText
        if !keyword.isEmpty {
            let haystack = [
                entry.note,
                entry.category?.name ?? "",
                entry.account?.name ?? "",
                entry.toAccount?.name ?? "",
            ]
            guard haystack.contains(where: { $0.localizedCaseInsensitiveContains(keyword) }) else { return false }
        }

        return true
    }

    func apply(to entries: [Entry]) -> [Entry] {
        entries.filter(matches)
    }
}
