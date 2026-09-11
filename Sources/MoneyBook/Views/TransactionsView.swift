import SwiftData
import SwiftUI

struct TransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\Entry.date, order: .reverse)]) private var entries: [Entry]
    @Query(sort: [SortDescriptor(\Account.sortOrder)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\EntryCategory.sortOrder)]) private var categories: [EntryCategory]

    @State private var selection = Set<Entry.ID>()
    @State private var pendingDeletion: Entry?

    private var filteredEntries: [Entry] {
        appState.activeFilter.apply(to: entries)
    }

    private var selectedEntries: [Entry] {
        entries.filter { selection.contains($0.id) }
    }

    private var totals: PeriodTotals {
        StatisticsService.periodTotals(entries: filteredEntries)
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            filterBar(appState: appState)
            Divider()

            if filteredEntries.isEmpty {
                EmptyStateView(
                    symbolName: "list.bullet.rectangle",
                    title: entries.isEmpty ? "还没有任何流水" : "没有符合条件的流水",
                    message: entries.isEmpty ? "记下第一笔支出或收入，这里就会列出明细。" : "试着放宽时间范围或清除筛选条件。",
                    actionTitle: entries.isEmpty ? "记一笔" : "重置筛选",
                    action: {
                        if entries.isEmpty {
                            appState.showEntryEditor()
                        } else {
                            appState.filter = EntryFilter()
                            appState.rangePreset = .thisMonth
                        }
                    }
                )
                .frame(maxHeight: .infinity)
            } else {
                table(appState: appState)
            }

            Divider()
            summaryBar
        }
        .searchable(
            text: $appState.filter.searchText,
            placement: .toolbar,
            prompt: "搜索备注、分类或账户"
        )
        .navigationTitle("流水")
        .alert(
            "删除这笔流水？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("删除", role: .destructive) { delete([entry]) }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { entry in
            Text("\(Formatters.fullDate(entry.date)) · \(Formatters.signedCurrency(entry.amount, kind: entry.kind))，删除后无法恢复。")
        }
    }

    // MARK: - 子视图

    private func filterBar(appState: AppState) -> some View {
        @Bindable var appState = appState

        return VStack(alignment: .leading, spacing: 8) {
            RangePickerBar()

            HStack(spacing: 10) {
                Picker("账户", selection: $appState.filter.accountID) {
                    Text("全部账户").tag(UUID?.none)
                    ForEach(accounts) { account in
                        Text(account.name).tag(UUID?.some(account.uuid))
                    }
                }
                .frame(width: 150)

                Picker("类型", selection: $appState.filter.kind) {
                    Text("全部类型").tag(EntryKind?.none)
                    ForEach(EntryKind.allCases) { kind in
                        Text(kind.title).tag(EntryKind?.some(kind))
                    }
                }
                .frame(width: 130)

                Picker("分类", selection: $appState.filter.categoryID) {
                    Text("全部分类").tag(UUID?.none)
                    ForEach(categories) { category in
                        Text(category.name).tag(UUID?.some(category.uuid))
                    }
                }
                .frame(width: 150)

                Spacer()

                if appState.filter.isActive || appState.rangePreset != .thisMonth {
                    Button("重置筛选") {
                        appState.filter = EntryFilter()
                        appState.rangePreset = .thisMonth
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func table(appState: AppState) -> some View {
        Table(filteredEntries, selection: $selection) {
            TableColumn("日期") { entry in
                Text(Formatters.isoDate(entry.date))
                    .monospacedDigit()
            }
            .width(min: 88, ideal: 100, max: 120)

            TableColumn("分类") { entry in
                HStack(spacing: 6) {
                    IconBadge(symbolName: iconName(for: entry), colorHex: colorHex(for: entry), size: 18)
                    Text(categoryTitle(for: entry))
                        .lineLimit(1)
                }
            }
            .width(min: 110, ideal: 150)

            TableColumn("账户") { entry in
                Text(accountTitle(for: entry))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)

            TableColumn("备注") { entry in
                Text(entry.note.isEmpty ? "—" : entry.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("金额") { entry in
                AmountText(amount: entry.amount, kind: entry.kind)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 96, ideal: 120, max: 160)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { _ in
            if let entry = singleSelectedEntry {
                Button("编辑…") { appState.showEditor(for: entry) }
            }
            if !selectedEntries.isEmpty {
                Button("删除", role: .destructive) {
                    pendingDeletion = singleSelectedEntry ?? selectedEntries.first
                }
            }
        } primaryAction: { _ in
            if let entry = singleSelectedEntry {
                appState.showEditor(for: entry)
            }
        }
        .onDeleteCommand {
            delete(selectedEntries)
        }
    }

    private var singleSelectedEntry: Entry? {
        let selected = selectedEntries
        return selected.count == 1 ? selected.first : nil
    }

    private var summaryBar: some View {
        HStack(spacing: 16) {
            Text("\(filteredEntries.count) 笔")
                .foregroundStyle(.secondary)
            Spacer()
            Text("收入 \(Formatters.currency(totals.income))")
                .foregroundStyle(.green)
                .monospacedDigit()
            Text("支出 \(Formatters.currency(totals.expense))")
                .foregroundStyle(.red)
                .monospacedDigit()
            Text("结余 \(Formatters.currency(totals.net))")
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 行为

    private func delete(_ targets: [Entry]) {
        guard !targets.isEmpty else { return }
        for entry in targets {
            context.delete(entry)
        }
        selection.subtract(targets.map(\.id))
        pendingDeletion = nil
        try? context.save()
    }

    private func iconName(for entry: Entry) -> String {
        switch entry.kind {
        case .transfer: entry.kind.symbolName
        case .expense, .income: entry.category?.symbolName ?? "questionmark.circle"
        }
    }

    private func colorHex(for entry: Entry) -> String {
        switch entry.kind {
        case .transfer: "#8E8E93"
        case .expense, .income: entry.category?.colorHex ?? "#8E8E93"
        }
    }

    private func categoryTitle(for entry: Entry) -> String {
        switch entry.kind {
        case .transfer: "转账"
        case .expense, .income: entry.category?.name ?? "未分类"
        }
    }

    private func accountTitle(for entry: Entry) -> String {
        switch entry.kind {
        case .transfer:
            "\(entry.account?.name ?? "未知") → \(entry.toAccount?.name ?? "未知")"
        case .expense, .income:
            entry.account?.name ?? "未知账户"
        }
    }
}
