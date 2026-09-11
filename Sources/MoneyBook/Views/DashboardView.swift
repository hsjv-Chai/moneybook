import Charts
import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: [SortDescriptor(\Entry.date, order: .reverse)]) private var entries: [Entry]
    @Query(sort: [SortDescriptor(\Account.sortOrder)]) private var accounts: [Account]

    private var interval: DateInterval { appState.activeInterval }
    private var totals: PeriodTotals { StatisticsService.periodTotals(entries: entries, in: interval) }
    private var netWorth: Decimal { BalanceService.netWorth(accounts: accounts) }
    private var monthlyTotals: [MonthlyTotal] { StatisticsService.monthlyTotals(entries: entries, months: 6) }
    private var expenseBreakdown: [CategoryTotal] {
        StatisticsService.categoryBreakdown(entries: entries, in: interval, kind: .expense)
    }
    private var recentEntries: [Entry] { Array(entries.prefix(10)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RangePickerBar()

                HStack(spacing: 12) {
                    StatCard(
                        title: "收入",
                        amount: totals.income,
                        symbolName: EntryKind.income.symbolName,
                        tint: .green,
                        caption: Formatters.rangeTitle(interval)
                    )
                    StatCard(
                        title: "支出",
                        amount: totals.expense,
                        symbolName: EntryKind.expense.symbolName,
                        tint: .red,
                        caption: Formatters.rangeTitle(interval)
                    )
                    StatCard(
                        title: "结余",
                        amount: totals.net,
                        symbolName: "equal.circle",
                        tint: totals.net >= 0 ? .accentColor : .orange,
                        caption: "收入 − 支出"
                    )
                    StatCard(
                        title: "总资产",
                        amount: netWorth,
                        symbolName: "banknote",
                        tint: .blue,
                        caption: "\(accounts.count) 个账户"
                    )
                }

                HStack(alignment: .top, spacing: 12) {
                    ChartCard(
                        title: "近 6 个月收支",
                        subtitle: "单位为元"
                    ) {
                        MonthlyTrendChart(totals: monthlyTotals)
                    } legend: {
                        HStack(spacing: 10) {
                            LegendDot(title: "收入", color: .green)
                            LegendDot(title: "支出", color: .red)
                        }
                    }

                    ChartCard(
                        title: "支出构成",
                        subtitle: Formatters.rangeTitle(interval)
                    ) {
                        if expenseBreakdown.isEmpty {
                            EmptyStateView(
                                symbolName: "chart.pie",
                                title: "暂无支出数据",
                                message: "记一笔支出后这里会显示分类占比。"
                            )
                        } else {
                            CategoryDonutChart(items: expenseBreakdown)
                        }
                    }
                }

                ChartCard(title: "最近流水", subtitle: "最新的 10 笔记录") {
                    if recentEntries.isEmpty {
                        EmptyStateView(
                            symbolName: "list.bullet.rectangle",
                            title: "还没有任何流水",
                            message: "从记下第一笔开始，概览会实时更新。",
                            actionTitle: "记一笔",
                            action: { appState.showEntryEditor() }
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(recentEntries) { entry in
                                EntryRowContent(entry: entry)
                                    .padding(.vertical, 6)
                                if entry.persistentModelID != recentEntries.last?.persistentModelID {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("概览")
        .navigationSubtitle(Formatters.rangeTitle(interval))
    }
}

struct MonthlyTrendChart: View {
    let totals: [MonthlyTotal]

    var body: some View {
        Chart {
            ForEach(totals) { total in
                BarMark(
                    x: .value("月份", total.month, unit: .month),
                    y: .value("金额", total.income.doubleValue)
                )
                .foregroundStyle(Color.green)
                .position(by: .value("类型", "收入"))
                .cornerRadius(3)

                BarMark(
                    x: .value("月份", total.month, unit: .month),
                    y: .value("金额", total.expense.doubleValue)
                )
                .foregroundStyle(Color.red)
                .position(by: .value("类型", "支出"))
                .cornerRadius(3)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.defaultDigits))
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 190)
    }
}

struct CategoryDonutChart: View {
    let items: [CategoryTotal]

    private var total: Decimal {
        items.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Chart(items) { item in
                SectorMark(
                    angle: .value("金额", item.amount.doubleValue),
                    innerRadius: .ratio(0.62),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(Color(hex: item.colorHex))
            }
            .frame(width: 158, height: 190)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.prefix(6)) { item in
                    LegendDot(
                        title: item.name,
                        color: Color(hex: item.colorHex),
                        value: shareText(for: item)
                    )
                }
                if items.count > 6 {
                    Text("另有 \(items.count - 6) 个分类")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 190)
    }

    private func shareText(for item: CategoryTotal) -> String {
        guard total > 0 else { return Formatters.currency(item.amount) }
        let ratio = (item.amount.doubleValue / total.doubleValue) * 100
        return String(format: "%.1f%%", ratio)
    }
}
