import AppKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }

            CategorySettingsView()
                .tabItem { Label("分类", systemImage: "tag") }

            DataSettingsView()
                .tabItem { Label("数据", systemImage: "externaldrive") }
        }
        .padding(16)
    }
}

// MARK: - 通用

struct GeneralSettingsView: View {
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]

    @AppStorage(PreferenceKeys.defaultAccountID) private var defaultAccountID = ""
    @AppStorage(PreferenceKeys.showArchivedAccounts) private var showArchivedAccounts = false
    @AppStorage(PreferenceKeys.showArchivedCategories) private var showArchivedCategories = false

    var body: some View {
        Form {
            Section("记账") {
                Picker("默认账户", selection: $defaultAccountID) {
                    Text("每次手动选择").tag("")
                    ForEach(accounts.filter { !$0.isArchived }) { account in
                        Text(account.name).tag(account.uuid.uuidString)
                    }
                }
            }

            Section("显示") {
                Toggle("在账户页显示已归档账户", isOn: $showArchivedAccounts)
                Toggle("在分类管理中显示已归档分类", isOn: $showArchivedCategories)
            }

            Section("关于") {
                LabeledContent("应用") {
                    Text("记账本 1.0")
                }
                LabeledContent("数据存储") {
                    Text("全部数据仅保存在本机，不联网、不上传。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 分类管理

struct CategorySettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\EntryCategory.sortOrder), SortDescriptor(\EntryCategory.createdAt)])
    private var categories: [EntryCategory]

    @AppStorage(PreferenceKeys.showArchivedCategories) private var showArchivedCategories = false

    @State private var editorTarget: CategoryEditorTarget?
    @State private var activeAlert: CategoryAlert?

    private enum CategoryAlert: Identifiable {
        case confirmDelete(EntryCategory)
        case blockedDelete(EntryCategory)

        var id: String {
            switch self {
            case .confirmDelete(let category): "delete-\(category.uuid.uuidString)"
            case .blockedDelete(let category): "blocked-\(category.uuid.uuidString)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("显示已归档分类", isOn: $showArchivedCategories)
                .toggleStyle(.checkbox)

            List {
                section(for: .expense)
                section(for: .income)
            }
            .listStyle(.inset)
        }
        .sheet(item: $editorTarget) { target in
            CategoryEditorSheet(kind: target.kind, category: target.category)
        }
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } }
            ),
            presenting: activeAlert
        ) { alert in
            switch alert {
            case .confirmDelete(let category):
                Button("删除", role: .destructive) {
                    context.delete(category)
                    activeAlert = nil
                    try? context.save()
                }
                Button("取消", role: .cancel) { activeAlert = nil }
            case .blockedDelete(let category):
                Button("改为归档") {
                    category.isArchived = true
                    activeAlert = nil
                    try? context.save()
                }
                Button("取消", role: .cancel) { activeAlert = nil }
            }
        } message: { alert in
            switch alert {
            case .confirmDelete(let category):
                Text("「\(category.name)」没有流水引用，可以安全删除。")
            case .blockedDelete(let category):
                Text("「\(category.name)」有 \(DeletionGuard.blockingEntryCount(for: category)) 笔流水引用，建议归档而不是删除。")
            }
        }
    }

    private var alertTitle: String {
        switch activeAlert {
        case .confirmDelete: "删除分类？"
        case .blockedDelete: "无法删除该分类"
        case nil: ""
        }
    }

    private func section(for kind: CategoryKind) -> some View {
        Section(kind.title) {
            ForEach(visibleCategories(of: kind)) { category in
                row(for: category)
                    .contextMenu {
                        Button("编辑…") {
                            editorTarget = CategoryEditorTarget(kind: kind, category: category)
                        }
                        Button(category.isArchived ? "取消归档" : "归档") {
                            category.isArchived.toggle()
                            try? context.save()
                        }
                        Divider()
                        Button("删除…", role: .destructive) { requestDeletion(of: category) }
                    }
            }

            Button {
                editorTarget = CategoryEditorTarget(kind: kind, category: nil)
            } label: {
                Label("新增\(kind.title)", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.link)
        }
    }

    private func row(for category: EntryCategory) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbolName: category.symbolName, colorHex: category.colorHex, size: 20)
            Text(category.name)
            if category.isArchived {
                Text("已归档")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(category.entries.count) 笔")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func visibleCategories(of kind: CategoryKind) -> [EntryCategory] {
        categories
            .filter { $0.kind == kind && (showArchivedCategories || !$0.isArchived) }
    }

    private func requestDeletion(of category: EntryCategory) {
        if DeletionGuard.canDelete(category) {
            activeAlert = .confirmDelete(category)
        } else {
            activeAlert = .blockedDelete(category)
        }
    }
}

struct CategoryEditorTarget: Identifiable {
    let id = UUID()
    let kind: CategoryKind
    let category: EntryCategory?
}

/// 分类新增/编辑面板。
struct CategoryEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let kind: CategoryKind
    private let editingCategory: EntryCategory?

    @State private var name: String
    @State private var symbolName: String
    @State private var colorHex: String
    @State private var isArchived: Bool
    @State private var validationMessage: String?
    @FocusState private var nameFocused: Bool

    init(kind: CategoryKind, category: EntryCategory?) {
        self.kind = kind
        editingCategory = category
        _name = State(initialValue: category?.name ?? "")
        _symbolName = State(initialValue: category?.symbolName ?? "tag")
        _colorHex = State(initialValue: category?.colorHex ?? Palette.categoryColors[0])
        _isArchived = State(initialValue: category?.isArchived ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingCategory == nil ? "新增\(kind.title)" : "编辑分类")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                        .foregroundStyle(.secondary)
                    TextField("例如「宠物」", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                }

                GridRow {
                    Text("图标")
                        .foregroundStyle(.secondary)
                    SymbolPicker(symbols: Palette.categorySymbols, selection: $symbolName)
                }

                GridRow {
                    Text("颜色")
                        .foregroundStyle(.secondary)
                    ColorSwatchPicker(colors: Palette.categoryColors, selection: $colorHex)
                }

                if editingCategory != nil {
                    GridRow {
                        Text("状态")
                            .foregroundStyle(.secondary)
                        Toggle("已归档", isOn: $isArchived)
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .font(.callout)

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
                Button(editingCategory == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "请填写分类名称。"
            return
        }

        if let editingCategory {
            editingCategory.name = trimmed
            editingCategory.symbolName = symbolName
            editingCategory.colorHex = colorHex
            editingCategory.isArchived = isArchived
        } else {
            context.insert(
                EntryCategory(
                    name: trimmed,
                    kind: kind,
                    symbolName: symbolName,
                    colorHex: colorHex,
                    sortOrder: nextSortOrder()
                )
            )
        }

        try? context.save()
        dismiss()
    }

    private func nextSortOrder() -> Int {
        let descriptor = FetchDescriptor<EntryCategory>(sortBy: [SortDescriptor(\.sortOrder, order: .reverse)])
        let highest = (try? context.fetch(descriptor).first?.sortOrder) ?? nil
        return (highest ?? 0) + 1
    }
}

// MARK: - 数据

struct DataSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @Query private var accounts: [Account]

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("数据库") {
                LabeledContent("文件位置") {
                    Text(PersistenceController.storeURL().path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }

                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([PersistenceController.storeURL()])
                }
            }

            Section("统计") {
                LabeledContent("流水") { Text("\(entries.count) 笔") }
                LabeledContent("账户") { Text("\(accounts.count) 个") }
            }

            Section("危险操作") {
                Button("清空全部数据…", role: .destructive) {
                    showResetConfirmation = true
                }
                Text("清空后仅保留默认账户与分类，所有流水无法恢复。建议先备份数据库文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "确定清空全部数据？",
            isPresented: $showResetConfirmation
        ) {
            Button("清空全部数据", role: .destructive) {
                try? SeedDataService.resetAll(in: context)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除所有流水、账户与自定义分类，且无法撤销。")
        }
    }
}
