import Foundation
import SwiftData

/// 资金账户：现金、银行卡、信用卡、电子钱包等。
@Model
final class Account {
    var uuid: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AccountKind.other.rawValue
    var initialBalance: Decimal = Decimal.zero
    var symbolName: String = AccountKind.other.symbolName
    var colorHex: String = Palette.accountColors[0]
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()

    /// 以本账户作为转出方的全部流水（支出、收入，以及作为转出账户的转账）。
    @Relationship(deleteRule: .nullify, inverse: \Entry.account)
    var entries: [Entry] = []

    /// 以本账户作为转入方的转账流水。
    @Relationship(deleteRule: .nullify, inverse: \Entry.toAccount)
    var incomingTransfers: [Entry] = []

    init(
        name: String,
        kind: AccountKind = .cash,
        initialBalance: Decimal = .zero,
        symbolName: String? = nil,
        colorHex: String = Palette.accountColors[0],
        sortOrder: Int = 0,
        isArchived: Bool = false,
        createdAt: Date = Date()
    ) {
        self.uuid = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.initialBalance = initialBalance
        self.symbolName = symbolName ?? kind.symbolName
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
        self.createdAt = createdAt
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}
