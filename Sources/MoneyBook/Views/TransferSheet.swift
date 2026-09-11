import SwiftData
import SwiftUI

/// 转账面板：在两个账户之间移动资金，可用作新建或编辑。
struct TransferSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Account.sortOrder)]) private var accounts: [Account]

    private let editingEntry: Entry?

    @State private var amountText: String
    @State private var fromAccountID: UUID?
    @State private var toAccountID: UUID?
    @State private var date: Date
    @State private var note: String
    @State private var validationMessage: String?
    @FocusState private var amountFocused: Bool

    init(entry: Entry?) {
        editingEntry = entry
        _amountText = State(initialValue: entry.map { Formatters.amount($0.amount) } ?? "")
        _fromAccountID = State(initialValue: entry?.account?.uuid)
        _toAccountID = State(initialValue: entry?.toAccount?.uuid)
        _date = State(initialValue: entry?.date ?? Date())
        _note = State(initialValue: entry?.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingEntry == nil ? "转账" : "编辑转账")
                .font(.title3.weight(.semibold))

            amountField

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("转出账户")
                        .foregroundStyle(.secondary)
                    Picker("转出账户", selection: $fromAccountID) {
                        ForEach(accounts) { account in
                            Text(balanceLabel(for: account)).tag(UUID?.some(account.uuid))
                        }
                    }
                    .labelsHidden()
                }

                GridRow {
                    Text("转入账户")
                        .foregroundStyle(.secondary)
                    Picker("转入账户", selection: $toAccountID) {
                        ForEach(accounts) { account in
                            Text(balanceLabel(for: account)).tag(UUID?.some(account.uuid))
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
                    TextField("可选，例如「取现」", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .font(.callout)

            if accounts.count < 2 {
                Label("至少需要两个账户才能转账，可先在「账户」页新增。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
                    .disabled(accounts.count < 2)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            amountFocused = true
            applyDefaultAccountsIfNeeded()
        }
    }

    private var amountField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("¥")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            TextField("0.00", text: $amountText)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .focused($amountFocused)
                .onSubmit { save() }
        }
        .cardStyle()
    }

    private func balanceLabel(for account: Account) -> String {
        let balance = BalanceService.balance(of: account)
        let suffix = account.isArchived ? "（已归档）" : ""
        return "\(account.name)\(suffix) · \(Formatters.currency(balance))"
    }

    private func applyDefaultAccountsIfNeeded() {
        let active = accounts.filter { !$0.isArchived }
        if fromAccountID == nil { fromAccountID = active.first?.uuid }
        if toAccountID == nil { toAccountID = active.dropFirst().first?.uuid }
    }

    private func save() {
        guard let amount = Formatters.parseAmount(amountText) else {
            validationMessage = "请输入正确的金额，例如 500。"
            return
        }

        let from = accounts.first { $0.uuid == fromAccountID }
        let to = accounts.first { $0.uuid == toAccountID }

        do {
            try EntryValidator.validate(kind: .transfer, amount: amount, category: nil, account: from, toAccount: to)
        } catch let error as EntryValidationError {
            validationMessage = error.errorDescription
            return
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        if let editingEntry {
            editingEntry.kind = .transfer
            editingEntry.amount = amount.roundedToCents()
            editingEntry.account = from
            editingEntry.toAccount = to
            editingEntry.category = nil
            editingEntry.date = date
            editingEntry.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            editingEntry.updatedAt = Date()
        } else {
            context.insert(
                Entry(
                    date: date,
                    kind: .transfer,
                    amount: amount,
                    account: from,
                    toAccount: to,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        try? context.save()
        dismiss()
    }
}
