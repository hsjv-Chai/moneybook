import SwiftData
import SwiftUI

/// 账户编辑面板：新增或修改账户信息。
struct AccountEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private let editingAccount: Account?

    @State private var name: String
    @State private var kind: AccountKind
    @State private var initialBalanceText: String
    @State private var symbolName: String
    @State private var colorHex: String
    @State private var isArchived: Bool
    @State private var validationMessage: String?
    @FocusState private var nameFocused: Bool

    init(account: Account?) {
        editingAccount = account
        _name = State(initialValue: account?.name ?? "")
        _kind = State(initialValue: account?.kind ?? .bankCard)
        _initialBalanceText = State(initialValue: account.map { Formatters.amount($0.initialBalance) } ?? "0.00")
        _symbolName = State(initialValue: account?.symbolName ?? AccountKind.bankCard.symbolName)
        _colorHex = State(initialValue: account?.colorHex ?? Palette.accountColors[0])
        _isArchived = State(initialValue: account?.isArchived ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingAccount == nil ? "新增账户" : "编辑账户")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                        .foregroundStyle(.secondary)
                    TextField("例如「招商银行卡」", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                }

                GridRow {
                    Text("类型")
                        .foregroundStyle(.secondary)
                    Picker("类型", selection: $kind) {
                        ForEach(AccountKind.allCases) { item in
                            Label(item.title, systemImage: item.symbolName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: kind) { _, newValue in
                        symbolName = newValue.symbolName
                    }
                }

                GridRow {
                    Text("期初余额")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("¥")
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $initialBalanceText)
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .frame(width: 140)
                    }
                }

                GridRow {
                    Text("图标")
                        .foregroundStyle(.secondary)
                    SymbolPicker(symbols: Palette.accountSymbols, selection: $symbolName)
                }

                GridRow {
                    Text("颜色")
                        .foregroundStyle(.secondary)
                    ColorSwatchPicker(colors: Palette.accountColors, selection: $colorHex)
                }

                if editingAccount != nil {
                    GridRow {
                        Text("状态")
                            .foregroundStyle(.secondary)
                        Toggle("已归档（不再用于新记账，历史记录保留）", isOn: $isArchived)
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
                Button(editingAccount == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { nameFocused = true }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "请填写账户名称。"
            return
        }

        let initialBalance = Formatters.parseAmount(initialBalanceText) ?? .zero

        if let editingAccount {
            editingAccount.name = trimmedName
            editingAccount.kind = kind
            editingAccount.initialBalance = initialBalance.roundedToCents()
            editingAccount.symbolName = symbolName
            editingAccount.colorHex = colorHex
            editingAccount.isArchived = isArchived
        } else {
            context.insert(
                Account(
                    name: trimmedName,
                    kind: kind,
                    initialBalance: initialBalance.roundedToCents(),
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
        let descriptor = FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder, order: .reverse)])
        let highest = (try? context.fetch(descriptor).first?.sortOrder) ?? 0
        return (highest ?? 0) + 1
    }
}

/// SF Symbol 图标选择器。
struct SymbolPicker: View {
    let symbols: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 24)
                        .background(
                            selection == symbol ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(selection == symbol ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5))
                        )
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
        }
    }
}

/// 颜色选择器。
struct ColorSwatchPicker: View {
    let colors: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                Button {
                    selection = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(selection == hex ? 0.8 : 0), lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .help(hex)
            }
        }
    }
}
