import Charts
import SwiftData
import SwiftUI

struct InsightsView: View {
    @Environment(AppState.self) private var appState

    @Query(sort: [SortDescriptor(\Entry.date, order: .reverse)]) private var entries: [Entry]
    @Query(sort: [SortDescriptor(\Account.sortOrder)]) private var accounts: [Account]

    private var monthlyTotals: [MonthlyTotal] {
        StatisticsService.monthlyTotals(entries: entries, months: appState.insightsMonthCount)
    }

    private var categoryTotals: [CategoryTotal] {
        StatisticsService.categoryBreakdown(entries: entries, in: appState.activeInterval, kind: appState.insightsKind)
    }

    private var accountTotals: [AccountTotal] {
        StatisticsService.accountBreakdown(accounts: accounts.filter { !$0.isArchived })
    }

    private var rangeTotals: PeriodTotals {
        StatisticsService.periodTotals(entries: entries, in: appState.activeInterval)
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RangePickerBar()

                HStack(spacing: 12) {
                    StatCard(title: "区间收入", amount: rangeTotals.income, symbolName: "arrow.down.left", tint: .green)
                    StatCard(title: "区间支出", amount: rangeTotals.expense, symbolName: "arrow.up.right", tint: .red)
                    StatCard(title: "区间结余", amount: rangeTotals.net, symbolName: "equal.circle", tint: .accentColor)
                }

                ChartCard(
                    title: "月度收支趋势",
                    subtitle: "最近 \(appState.insightsMonthCount) 个月"
                ) {
                    MonthlyTrendChart(totals: monthlyTotals)
                } legend: {
                    HStack(spacing: 10) {
                        LegendDot(title: "收入", color: .green)
                        LegendDot(title: "支出", color: .red)
                        Picker("月份数", selection: $appState.insightsMonthCount) {
                            Text("6 个月").tag(6)
                            Text("12 个月").tag(12)
                            Text("24 个月").tag(24)
                        }
                        .labelsHidden()
                        .frame(width: 96)
                    }
                }

                ChartCard(
                    title: "分类排行",
                    subtitle: Formatters.rangeTitle(appState.activeInterval)
                ) {
                    if categoryTotals.isEmpty {
                        EmptyStateView(
                            symbolName: "chart.bar",
                            title: "暂无数据",
                            message: "当前时间范围内没有\(appState.insightsKind.title)记录。"
                        )
                    } else {
                        CategoryRankChart(items: categoryTotals)
                    }
                } legend: {
                    Picker("方向", selection: $appState.insightsKind) {
                        Text("支出").tag(EntryKind.expense)
                        Text("收入").tag(EntryKind.income)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }

                ChartCard(title: "账户余额分布", subtitle: "不含已归档账户") {
                    if accountTotals.isEmpty {
                        EmptyStateView(
                            symbolName: "creditcard",
                            title: "还没有账户",
                            message: "新增账户后可以在这里对比余额。"
                        )
                    } else {
                        AccountBalanceChart(items: accountTotals)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("统计")
        .navigationSubtitle(Formatters.rangeTitle(appState.activeInterval))
    }
}

/// 分类金额排行（横向条形图）。
struct CategoryRankChart: View {
    let items: [CategoryTotal]

    private var total: Decimal {
        items.reduce(Decimal.zero) { $0 + $1.amount }
    }

    var body: some View {
        let top = Array(items.prefix(10))

        Chart(top) { item in
            BarMark(
                x: .value("金额", item.amount.doubleValue),
                y: .value("分类", item.name)
            )
            .foregroundStyle(Color(hex: item.colorHex))
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text(shareText(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .chartXAxis { AxisMarks(position: .bottom) }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: max(160, CGFloat(top.count) * 30))
    }

    private func shareText(for item: CategoryTotal) -> String {
        let share = total > 0 ? item.amount.doubleValue / total.doubleValue * 100 : 0
        return "\(Formatters.currency(item.amount)) · \(String(format: "%.0f%%", share))"
    }
}

/// 账户余额分布。
struct AccountBalanceChart: View {
    let items: [AccountTotal]

    var body: some View {
        Chart(items) { item in
            BarMark(
                x: .value("余额", item.balance.doubleValue),
                y: .value("账户", item.name)
            )
            .foregroundStyle(Color(hex: item.colorHex))
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text(Formatters.currency(item.balance))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .chartXAxis { AxisMarks(position: .bottom) }
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: max(140, CGFloat(items.count) * 32))
    }
}
