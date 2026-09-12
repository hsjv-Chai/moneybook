import SwiftData
import SwiftUI

/// 合并浮层：把选中的几笔收支并成一条净额流水。
struct MergeEntriesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\EntryCategory.sortOrder)]) private var categories: [EntryCategory]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]

    private let entries: [Entry]

    @State private var date: Date
    @State private var kind: EntryKind
    @State private var amount: Decimal
    @State private var categoryUUID: UUID?
    @State private var accountUUID: UUID?
    @State private var note: String
    @State private var errorMessage: String?
    @State private var mergedEntry: Entry?
    @State private var restoredCount = 0

    init(entries: [Entry]) {
        self.entries = entries
        let draft = EntryMergeService.draft(for: entries, defaultCategory: nil)
        _date = State(initialValue: draft.date)
        _kind = State(initialValue: draft.kind)
        _amount = State(initialValue: draft.amount)
        _categoryUUID = State(initialValue: draft.category?.uuid)
        _accountUUID = State(initialValue: draft.account?.uuid)
        _note = State(initialValue: draft.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let mergedEntry {
                finishedView(mergedEntry)
            } else {
                formView
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: applyDefaultCategoryIfNeeded)
    }

    // MARK: - 表单

    private var formView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("合并 \(entries.count) 笔流水")
                    .font(.title3.weight(.semibold))
                Text("支出为负、收入为正，合并后的金额是它们的净额。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sourceList
            netSummary

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("日期").foregroundStyle(.secondary)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                }
                GridRow {
                    Text("分类").foregroundStyle(.secondary)
                    Picker("分类", selection: $categoryUUID) {
                        ForEach(categoriesForKind) { category in
                            Text(category.name).tag(UUID?.some(category.uuid))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                GridRow {
                    Text("账户").foregroundStyle(.secondary)
                    Picker("账户", selection: $accountUUID) {
                        ForEach(accountsForPicker) { account in
                            Text(account.name).tag(UUID?.some(account.uuid))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                GridRow {
                    Text("说明").foregroundStyle(.secondary)
                    TextField("可选", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .font(.callout)

            Label(
                "合并后这 \(entries.count) 笔会被替换成 1 笔，原始流水会被删除（可在合并后撤销）。",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Text(Formatters.isoDate(entry.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(entry.isMergeResult ? "合并记录" : (entry.category?.name ?? (entry.kind == .transfer ? "转账" : "未分类")))
                        .font(.caption)
                        .lineLimit(1)
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    AmountText(amount: entry.amount, kind: entry.kind, font: .caption)
                }
                .padding(.vertical, 4)
                if entry.id != entries.last?.id { Divider() }
            }
        }
        .cardStyle(padding: 12)
    }

    private var netSummary: some View {
        let expenseTotal = entries.filter { $0.kind == .expense }.reduce(Decimal.zero) { $0 + $1.amount }
        let incomeTotal = entries.filter { $0.kind == .income }.reduce(Decimal.zero) { $0 + $1.amount }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("合并结果")
                    .font(.subheadline.weight(.semibold))
                Text(kind.title)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .separatorColor).opacity(0.3), in: Capsule())
                Spacer()
                Text(Formatters.currency(amount))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(kind == .expense ? Color.red : Color.green)
            }
            Text("支出 \(Formatters.currency(expenseTotal)) － 收入 \(Formatters.currency(incomeTotal)) = 净额 \(Formatters.currency(amount))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .cardStyle(padding: 12)
    }

    // MARK: - 完成态

    private func finishedView(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                restoredCount > 0 ? "已撤销合并，还原 \(restoredCount) 笔流水" : "已合并为 1 笔流水",
                systemImage: restoredCount > 0 ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(restoredCount > 0 ? Color.orange : Color.green)

            if restoredCount == 0 {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("日期").foregroundStyle(.secondary)
                        Text(Formatters.fullDate(entry.date))
                    }
                    GridRow {
                        Text("类型").foregroundStyle(.secondary)
                        Text(entry.kind.title)
                    }
                    GridRow {
                        Text("金额").foregroundStyle(.secondary)
                        AmountText(amount: entry.amount, kind: entry.kind)
                    }
                    GridRow {
                        Text("分类").foregroundStyle(.secondary)
                        Text(entry.category?.name ?? "未分类")
                    }
                    GridRow {
                        Text("账户").foregroundStyle(.secondary)
                        Text(entry.account?.name ?? "—")
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack {
            Spacer()
            if let mergedEntry, restoredCount == 0 {
                Button("撤销合并") { undo(mergedEntry) }
            }
            Button(mergedEntry == nil ? "取消" : "完成") { dismiss() }
                .keyboardShortcut(mergedEntry == nil ? .cancelAction : .defaultAction)
            if mergedEntry == nil {
                Button("合并") { performMerge() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 数据

    private var categoriesForKind: [EntryCategory] {
        let wanted: CategoryKind = kind == .income ? .income : .expense
        return categories.filter { $0.kind == wanted && !$0.isArchived }
    }

    private var accountsForPicker: [Account] {
        let active = accounts.filter { !$0.isArchived }
        if let accountUUID, let archived = accounts.first(where: { $0.uuid == accountUUID && $0.isArchived }) {
            return active + [archived]
        }
        return active
    }

    private func applyDefaultCategoryIfNeeded() {
        if categoryUUID == nil {
            let fallbackName = kind == .income ? "其他收入" : "其他支出"
            categoryUUID = categoriesForKind.first { $0.name == fallbackName }?.uuid
                ?? categoriesForKind.first?.uuid
        }
        if accountUUID == nil {
            accountUUID = accountsForPicker.first?.uuid
        }
    }

    // MARK: - 行为

    private func performMerge() {
        let draft = EntryMergeService.Draft(
            date: date,
            kind: kind,
            amount: amount,
            category: categories.first { $0.uuid == categoryUUID },
            account: accounts.first { $0.uuid == accountUUID },
            note: note
        )
        do {
            mergedEntry = try EntryMergeService.merge(entries, draft: draft, context: context)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undo(_ entry: Entry) {
        do {
            restoredCount = try EntryMergeService.undo(entry, context: context)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
