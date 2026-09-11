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
                Button {
                    appState.showEntryEditor()
                } label: {
                    Label("记一笔", systemImage: "square.and.pencil")
                }
                .help("记一笔（⌘N）")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showTransfer()
                } label: {
                    Label("转账", systemImage: "arrow.left.arrow.right")
                }
                .help("账户之间转账（⌘⇧T）")
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
