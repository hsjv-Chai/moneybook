import Foundation

/// 统计聚合：全部为纯计算，方便测试与复用。
@MainActor
enum StatisticsService {
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// 截止到 `endDate` 所在月份、向前共 `months` 个月的逐月收支（月份按升序返回，无数据月份补零）。
    static func monthlyTotals(
        entries: [Entry],
        months: Int,
        endingOn endDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [MonthlyTotal] {
        guard months > 0 else { return [] }
        guard
            let currentMonthStart = calendar.dateInterval(of: .month, for: endDate)?.start,
            let earliestMonthStart = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonthStart),
            let upperBound = calendar.date(byAdding: .month, value: 1, to: currentMonthStart)
        else { return [] }

        var buckets: [Date: (income: Decimal, expense: Decimal)] = [:]
        for offset in 0..<months {
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: earliestMonthStart) else { continue }
            buckets[monthStart] = (Decimal.zero, Decimal.zero)
        }

        for entry in entries {
            guard entry.kind != .transfer else { continue }
            guard entry.date >= earliestMonthStart, entry.date < upperBound else { continue }
            guard let monthStart = calendar.dateInterval(of: .month, for: entry.date)?.start else { continue }
            guard var bucket = buckets[monthStart] else { continue }

            switch entry.kind {
            case .income: bucket.income += entry.amount
            case .expense: bucket.expense += entry.amount
            case .transfer: break
            }
            buckets[monthStart] = bucket
        }

        return buckets.keys.sorted().map { month in
            let bucket = buckets[month] ?? (Decimal.zero, Decimal.zero)
            return MonthlyTotal(month: month, income: bucket.income, expense: bucket.expense)
        }
    }

    /// 指定方向下的分类合计，按金额从大到小排序。
    static func categoryBreakdown(
        entries: [Entry],
        in interval: DateInterval? = nil,
        kind: EntryKind
    ) -> [CategoryTotal] {
        guard kind != .transfer else { return [] }

        var totals: [UUID: CategoryTotal] = [:]
        for entry in entries {
            guard entry.kind == kind else { continue }
            if let interval, !interval.contains(entry.date) { continue }

            let identifier = entry.category?.uuid ?? uncategorizedID
            let amount = (totals[identifier]?.amount ?? .zero) + entry.amount
            totals[identifier] = CategoryTotal(
                categoryID: identifier,
                name: entry.category?.name ?? "未分类",
                symbolName: entry.category?.symbolName ?? "questionmark.circle",
                colorHex: entry.category?.colorHex ?? "#8E8E93",
                amount: amount
            )
        }

        return totals.values.sorted { $0.amount > $1.amount }
    }

    /// 各账户当前余额，按余额从大到小排序。
    static func accountBreakdown(accounts: [Account]) -> [AccountTotal] {
        accounts
            .map { account in
                AccountTotal(
                    accountID: account.uuid,
                    name: account.name,
                    symbolName: account.symbolName,
                    colorHex: account.colorHex,
                    balance: BalanceService.balance(of: account),
                    isArchived: account.isArchived
                )
            }
            .sorted { $0.balance > $1.balance }
    }

    /// 一段时间内的收入与支出合计（转账不计入）。
    static func periodTotals(entries: [Entry], in interval: DateInterval? = nil) -> PeriodTotals {
        var income = Decimal.zero
        var expense = Decimal.zero

        for entry in entries {
            if let interval, !interval.contains(entry.date) { continue }
            switch entry.kind {
            case .income: income += entry.amount
            case .expense: expense += entry.amount
            case .transfer: break
            }
        }

        return PeriodTotals(income: income.roundedToCents(), expense: expense.roundedToCents())
    }
}
