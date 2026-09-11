import SwiftData
import SwiftUI

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]

    @AppStorage(PreferenceKeys.showArchivedAccounts) private var showArchivedAccounts = false

    @State private var activeAlert: AccountAlert?

    private enum AccountAlert: Identifiable {
        case confirmDelete(Account)
        case blockedDelete(Account)

        var id: String {
            switch self {
            case .confirmDelete(let account): "delete-\(account.uuid.uuidString)"
            case .blockedDelete(let account): "blocked-\(account.uuid.uuidString)"
            }
        }

        var account: Account {
            switch self {
            case .confirmDelete(let account), .blockedDelete(let account): account
            }
        }
    }

    private var visibleAccounts: [Account] {
        showArchivedAccounts ? accounts : accounts.filter { !$0.isArchived }
    }

    private var netWorth: Decimal {
        BalanceService.netWorth(accounts: accounts)
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider()

            if visibleAccounts.isEmpty {
                EmptyStateView(
                    symbolName: "creditcard",
                    title: "还没有账户",
                    message: "添加银行卡、现金或电子钱包后即可开始记账。",
                    actionTitle: "新增账户",
                    action: { appState.showAccountEditor() }
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleAccounts) { account in
                        row(for: account)
                            .contextMenu {
                                Button("编辑…") { appState.showAccountEditor(account) }
                                Button(account.isArchived ? "取消归档" : "归档") {
                                    account.isArchived.toggle()
                                    try? context.save()
                                }
                                Divider()
                                Button("删除…", role: .destructive) { requestDeletion(of: account) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("账户")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showArchivedAccounts) {
                    Label("显示已归档", systemImage: showArchivedAccounts ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help("显示已归档账户")
            }
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
            case .confirmDelete(let account):
                Button("删除", role: .destructive) {
                    context.delete(account)
                    activeAlert = nil
                    try? context.save()
                }
                Button("取消", role: .cancel) { activeAlert = nil }
            case .blockedDelete(let account):
                Button("改为归档") {
                    account.isArchived = true
                    activeAlert = nil
                    try? context.save()
                }
                Button("取消", role: .cancel) { activeAlert = nil }
            }
        } message: { alert in
            switch alert {
            case .confirmDelete(let account):
                Text("「\(account.name)」没有任何流水记录，可以安全删除。")
            case .blockedDelete(let account):
                Text("「\(account.name)」有 \(DeletionGuard.blockingEntryCount(for: account)) 笔流水引用。删除会破坏历史记录，建议改为归档。")
            }
        }
    }

    private var alertTitle: String {
        switch activeAlert {
        case .confirmDelete: "删除账户？"
        case .blockedDelete: "无法删除该账户"
        case nil: ""
        }
    }

    // MARK: - 子视图

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("总资产")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Formatters.currency(netWorth))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            Spacer()

            Text("\(accounts.filter { !$0.isArchived }.count) 个在用账户")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                appState.showTransfer()
            } label: {
                Label("转账", systemImage: "arrow.left.arrow.right")
            }
            .disabled(accounts.count < 2)

            Button {
                appState.showAccountEditor()
            } label: {
                Label("新增账户", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func row(for account: Account) -> some View {
        let balance = BalanceService.balance(of: account)

        return HStack(spacing: 12) {
            IconBadge(symbolName: account.symbolName, colorHex: account.colorHex, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                    if account.isArchived {
                        Text("已归档")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: .separatorColor).opacity(0.3), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(account.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(Formatters.currency(balance))
                .monospacedDigit()
                .foregroundStyle(balance < 0 ? Color.red : Color.primary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 行为

    private func requestDeletion(of account: Account) {
        if DeletionGuard.canDelete(account) {
            activeAlert = .confirmDelete(account)
        } else {
            activeAlert = .blockedDelete(account)
        }
    }
}
