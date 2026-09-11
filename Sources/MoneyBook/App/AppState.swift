import Foundation
import Observation

/// 主窗口当前展示的浮层。
enum SheetRoute: Identifiable {
    case entry(Entry?)
    case transfer(Entry?)
    case account(Account?)
    case importBill

    var id: String {
        switch self {
        case .entry(let entry): "entry-\(entry?.uuid.uuidString ?? "new")"
        case .transfer(let entry): "transfer-\(entry?.uuid.uuidString ?? "new")"
        case .account(let account): "account-\(account?.uuid.uuidString ?? "new")"
        case .importBill: "import-bill"
        }
    }
}

/// 应用级共享状态：侧边栏选择、时间范围、筛选条件与浮层路由。
@Observable
@MainActor
final class AppState {
    var sidebarSelection: SidebarItem? = .dashboard
    var activeSheet: SheetRoute?

    var rangePreset: DateRangePreset = .thisMonth
    var customRange: DateInterval = DateRangePreset.thisMonth.interval() ?? DateInterval(start: Date(), duration: 0)
    var filter = EntryFilter()
    var insightsKind: EntryKind = .expense
    var insightsMonthCount: Int = 6

    /// 当前生效的时间区间（自定义时使用用户选择的区间）。
    var activeInterval: DateInterval {
        if rangePreset == .custom { return customRange }
        return rangePreset.interval() ?? customRange
    }

    /// 流水页使用的完整筛选条件（时间范围与 AppState 联动）。
    var activeFilter: EntryFilter {
        var result = filter
        result.range = activeInterval
        return result
    }

    func showEntryEditor(_ entry: Entry? = nil) {
        activeSheet = .entry(entry)
    }

    func showTransfer(_ entry: Entry? = nil) {
        activeSheet = .transfer(entry)
    }

    func showAccountEditor(_ account: Account? = nil) {
        activeSheet = .account(account)
    }

    func showBillImporter() {
        activeSheet = .importBill
    }

    /// 根据流水类型选择合适的编辑界面：转账走转账面板，其余走记账面板。
    func showEditor(for entry: Entry) {
        if entry.kind == .transfer {
            showTransfer(entry)
        } else {
            showEntryEditor(entry)
        }
    }

    func setCustomRangeStart(_ date: Date, calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: date)
        let minimumEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let end = max(customRange.end, minimumEnd)
        customRange = DateInterval(start: start, end: end)
    }

    func setCustomRangeEnd(_ date: Date, calendar: Calendar = .current) {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        let start = min(customRange.start, calendar.startOfDay(for: date))
        customRange = DateInterval(start: start, end: max(end, start.addingTimeInterval(86_400)))
    }
}
