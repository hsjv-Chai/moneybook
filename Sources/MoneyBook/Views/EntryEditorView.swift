import SwiftData
import SwiftUI

/// 记账面板：新增或编辑一笔支出/收入。
struct EntryEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Account.sortOrder)]) private var accounts: [Account]
    @Query(sort: [SortDescriptor(\EntryCategory.sortOrder)]) private var categories: [EntryCategory]
    @AppStorage(PreferenceKeys.defaultAccountID) private var defaultAccountID: String = ""

    private let editingEntry: Entry?

    @State private var kind: EntryKind
    @State private var amountText: String
    @State private var selectedCategoryID: UUID?
    @State private var selectedAccountID: UUID?
    @State private var date: Date
    @State private var note: String
    @State private var validationMessage: String?
    @FocusState private var amountFocused: Bool

    init(entry: Entry?) {
        editingEntry = entry
        // 转账有独立面板，这里只处理支出/收入。
        let initialKind = (entry?.kind ?? .expense) == .transfer ? .expense : (entry?.kind ?? .expense)
        _kind = State(initialValue: initialKind)
        _amountText = State(initialValue: entry.map { Formatters.amount($0.amount) } ?? "")
        _selectedCategoryID = State(initialValue: entry?.category?.uuid)
        _selectedAccountID = State(initialValue: entry?.account?.uuid)
        _date = State(initialValue: entry?.date ?? Date())
        _note = State(initialValue: entry?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            amountField
            categorySection
            detailSection

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editingEntry == nil ? "保存" : "更新") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            amountFocused = true
            applyDefaultAccountIfNeeded()
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack {
            Text(editingEntry == nil ? "记一笔" : "编辑流水")
                .font(.title3.weight(.semibold))
            Spacer()
            Picker("类型", selection: $kind) {
                ForEach(EntryKind.manualKinds) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .onChange(of: kind) { _, _ in
                ensureCategoryMatchesKind()
            }
        }
    }

    private var amountField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kind == .expense ? "−¥" : "+¥")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(kind == .expense ? Color.red : Color.green)

            TextField("0.00", text: $amountText)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .focused($amountFocused)
                .onSubmit { save() }
        }
        .cardStyle()
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if visibleCategories.isEmpty {
                EmptyStateView(
                    symbolName: "tag",
                    title: "还没有可用分类",
                    message: "可以在「设置 → 分类」中新增\(categoryKind.title)。"
                )
            } else {
                CategoryChipGrid(categories: visibleCategories, selection: $selectedCategoryID)
            }
        }
    }

    private var detailSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("账户")
                    .foregroundStyle(.secondary)
                Picker("账户", selection: $selectedAccountID) {
                    ForEach(visibleAccounts) { account in
                        Text(account.name).tag(UUID?.some(account.uuid))
                    }
                }
                .labelsHidden()
            }

            GridRow {
                Text("日期")
                    .foregroundStyle(.secondary)
                DatePicker("日期", selection: $date, displayedComponents: .date)
                    .labelsHidden()
            }

            GridRow {
                Text("备注")
                    .foregroundStyle(.secondary)
                TextField("可选，例如「和同事聚餐」", text: $note)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .font(.callout)
    }

    // MARK: - 派生数据

    private var categoryKind: CategoryKind {
        kind == .income ? .income : .expense
    }

    private var visibleCategories: [EntryCategory] {
        categories.filter { $0.kind == categoryKind && !$0.isArchived }
    }

    private var visibleAccounts: [Account] {
        let active = accounts.filter { !$0.isArchived }
        if let selectedAccountID,
           let archived = accounts.first(where: { $0.uuid == selectedAccountID && $0.isArchived }) {
            return active + [archived]
        }
        return active
    }

    // MARK: - 行为

    private func applyDefaultAccountIfNeeded() {
        guard editingEntry == nil, selectedAccountID == nil else { return }
        let active = accounts.filter { !$0.isArchived }
        if let defaultAccount = active.first(where: { $0.uuid.uuidString == defaultAccountID }) {
            selectedAccountID = defaultAccount.uuid
        } else {
            selectedAccountID = active.first?.uuid
        }
    }

    private func ensureCategoryMatchesKind() {
        guard let selectedCategoryID,
              let category = categories.first(where: { $0.uuid == selectedCategoryID })
        else { return }
        if category.kind != categoryKind {
            self.selectedCategoryID = nil
        }
    }

    private func save() {
        guard let amount = Formatters.parseAmount(amountText) else {
            validationMessage = "请输入正确的金额，例如 25.80。"
            return
        }

        let category = categories.first { $0.uuid == selectedCategoryID }
        let account = accounts.first { $0.uuid == selectedAccountID }

        do {
            try EntryValidator.validate(kind: kind, amount: amount, category: category, account: account)
        } catch let error as EntryValidationError {
            validationMessage = error.errorDescription
            return
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        if let editingEntry {
            editingEntry.kind = kind
            editingEntry.amount = amount.roundedToCents()
            editingEntry.category = category
            editingEntry.account = account
            editingEntry.toAccount = nil
            editingEntry.date = date
            editingEntry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            editingEntry.updatedAt = Date()
        } else {
            context.insert(
                Entry(
                    date: date,
                    kind: kind,
                    amount: amount,
                    category: category,
                    account: account,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        try? context.save()
        dismiss()
    }
}

/// 分类快捷选择网格。
struct CategoryChipGrid: View {
    let categories: [EntryCategory]
    @Binding var selection: UUID?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(categories) { category in
                    chip(for: category)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 168)
    }

    private func chip(for category: EntryCategory) -> some View {
        let isSelected = selection == category.uuid
        let color = Color(hex: category.colorHex)

        return Button {
            selection = category.uuid
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(category.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? color.opacity(0.22) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? color : Color(nsColor: .separatorColor).opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }
}
