import AppKit
import SwiftData
import SwiftUI

@main
struct MoneyBookMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            let succeeded = SelfTestRunner.run()
            exit(succeeded ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--import-preview"),
           index + 1 < CommandLine.arguments.count {
            let succeeded = BillImportCLI.run(path: CommandLine.arguments[index + 1])
            exit(succeeded ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--import-debug"),
           index + 1 < CommandLine.arguments.count {
            let succeeded = BillImportCLI.debug(path: CommandLine.arguments[index + 1])
            exit(succeeded ? 0 : 1)
        }
        if CommandLine.arguments.contains("--check-store") {
            exit(BillImportCLI.checkStore() ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--import-apply"),
           index + 1 < CommandLine.arguments.count {
            exit(BillImportCLI.apply(path: CommandLine.arguments[index + 1]) ? 0 : 1)
        }
        MoneyBookApp.main()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
struct MoneyBookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    private let container: ModelContainer

    init() {
        do {
            let container = try PersistenceController.makeContainer()
            try SeedDataService.seedIfNeeded(in: ModelContext(container))
            self.container = container
        } catch {
            fatalError("无法创建本地数据库：\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .modelContainer(container)
        .commands { MoneyBookCommands(appState: appState) }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(container)
                .frame(width: 620, height: 480)
        }
    }
}

@MainActor
struct MoneyBookCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("记一笔…") { appState.showEntryEditor() }
                .keyboardShortcut("n", modifiers: .command)

            Button("转账…") { appState.showTransfer() }
                .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("导入微信账单…") { appState.showBillImporter() }
                .keyboardShortcut("i", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) { appState.sidebarSelection = item }
            }
        }

        SidebarCommands()
    }
}
