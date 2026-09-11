import Foundation

/// 一笔流水的类型。
enum EntryKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case expense
    case income
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        }
    }

    var symbolName: String {
        switch self {
        case .expense: "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        }
    }

    /// 对净资产的影响方向：支出 −1、收入 +1、转账 0（转账只在账户之间移动资金）。
    var netSign: Decimal {
        switch self {
        case .expense: -1
        case .income: 1
        case .transfer: 0
        }
    }

    /// 记账时可以手动选择的类型（转账走单独的入口）。
    static var manualKinds: [EntryKind] { [.expense, .income] }
}

/// 账户类型。
enum AccountKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cash
    case bankCard
    case creditCard
    case eWallet
    case investment
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: "现金"
        case .bankCard: "银行卡"
        case .creditCard: "信用卡"
        case .eWallet: "电子钱包"
        case .investment: "投资"
        case .other: "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .cash: "banknote"
        case .bankCard: "creditcard"
        case .creditCard: "creditcard.fill"
        case .eWallet: "wallet.pass"
        case .investment: "chart.line.uptrend.xyaxis"
        case .other: "square.grid.2x2"
        }
    }

    /// 信用卡这类负债账户允许余额为负。
    var allowsNegativeBalance: Bool { self == .creditCard }
}

/// 分类归属的收支方向。
enum CategoryKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case expense
    case income

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: "支出分类"
        case .income: "收入分类"
        }
    }

    var entryKind: EntryKind {
        switch self {
        case .expense: .expense
        case .income: .income
        }
    }
}

/// 侧边栏目的地。
enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case transactions
    case accounts
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "概览"
        case .transactions: "流水"
        case .accounts: "账户"
        case .insights: "统计"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2"
        case .transactions: "list.bullet.rectangle"
        case .accounts: "creditcard"
        case .insights: "chart.pie"
        }
    }
}
