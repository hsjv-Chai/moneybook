import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView(selection: $appState.sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("记一笔…") { appState.showEntryEditor() }
                    Button("转账…") { appState.showTransfer() }
                    Divider()
                    Button("导入微信账单…") { appState.showBillImporter() }
                } label: {
                    Label("记一笔", systemImage: "square.and.pencil")
                }
                .help("记一笔（⌘N）、转账（⌘⇧T）、导入账单（⌘I）")
            }
        }
        .sheet(item: $appState.activeSheet) { route in
            switch route {
            case .entry(let entry):
                EntryEditorView(entry: entry)
            case .transfer(let entry):
                TransferSheet(entry: entry)
            case .account(let account):
                AccountEditorView(account: account)
            case .importBill:
                ImportBillView()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.sidebarSelection ?? .dashboard {
        case .dashboard:
            DashboardView()
        case .transactions:
            TransactionsView()
        case .accounts:
            AccountsView()
        case .insights:
            InsightsView()
        }
    }
}
