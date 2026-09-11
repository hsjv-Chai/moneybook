import Foundation

/// 账户余额与净资产计算。
@MainActor
enum BalanceService {
    /// 期初余额 + 收入 − 支出 + 转入 − 转出。
    static func balance(of account: Account) -> Decimal {
        var total = account.initialBalance

        for entry in account.entries {
            total += entry.sourceAccountDelta
        }
        for entry in account.incomingTransfers {
            total += entry.amount
        }

        return total.roundedToCents()
    }

    /// 所有账户余额之和（含已归档账户，其资金仍然存在）。
    static func netWorth(accounts: [Account]) -> Decimal {
        accounts.reduce(Decimal.zero) { $0 + balance(of: $1) }.roundedToCents()
    }
}

/// 删除保护：有流水引用时只允许归档，不允许硬删除。
@MainActor
enum DeletionGuard {
    static func canDelete(_ account: Account) -> Bool {
        account.entries.isEmpty && account.incomingTransfers.isEmpty
    }

    static func canDelete(_ category: EntryCategory) -> Bool {
        category.entries.isEmpty
    }

    static func blockingEntryCount(for account: Account) -> Int {
        account.entries.count + account.incomingTransfers.count
    }

    static func blockingEntryCount(for category: EntryCategory) -> Int {
        category.entries.count
    }
}
