import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("记账") {
                ForEach([SidebarItem.dashboard, .transactions]) { item in
                    Label(item.title, systemImage: item.symbolName)
                        .tag(item)
                }
            }

            Section("资产") {
                ForEach([SidebarItem.accounts, .insights]) { item in
                    Label(item.title, systemImage: item.symbolName)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("记账本")
    }
}
