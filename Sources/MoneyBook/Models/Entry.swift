import Foundation
import SwiftData

/// 一笔流水：支出、收入或转账。
@Model
final class Entry {
    var uuid: UUID = UUID()
    var date: Date = Date()
    var kindRaw: String = EntryKind.expense.rawValue
    /// 金额恒为正数，方向由 kind 决定。
    var amount: Decimal = Decimal.zero
    var note: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 导入来源的稳定标识（例如微信交易单号），用于避免重复导入。
    var externalID: String?
    /// 同一次导入的批次标识，便于整批撤销。
    var importBatchID: UUID?

    /// 合并流水时保存被合并掉的原始记录（JSON），用于撤销合并。
    var mergedSourceData: Data?
    /// 被合并掉的流水笔数，便于列表直接展示。
    var mergedSourceCount: Int = 0

    /// 支出/收入的所属账户；转账时为转出账户。
    var account: Account?
    /// 仅转账使用：转入账户。
    var toAccount: Account?
    /// 支出/收入必填；转账时为空。
    var category: EntryCategory?

    init(
        date: Date,
        kind: EntryKind,
        amount: Decimal,
        category: EntryCategory? = nil,
        account: Account? = nil,
        toAccount: Account? = nil,
        note: String = "",
        externalID: String? = nil,
        importBatchID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.uuid = UUID()
        self.date = date
        self.kindRaw = kind.rawValue
        self.amount = amount.roundedToCents()
        self.category = category
        self.account = account
        self.toAccount = toAccount
        self.note = note
        self.externalID = externalID
        self.importBatchID = importBatchID
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var kind: EntryKind {
        get { EntryKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    /// 对净资产的影响：支出为负、收入为正、转账为零。
    var netAmount: Decimal { amount * kind.netSign }

    /// 从「转出账户」视角看到的余额变化：转账为负，其余与 netAmount 一致。
    var sourceAccountDelta: Decimal {
        kind == .transfer ? -amount : netAmount
    }

    var isArchivedContent: Bool {
        (account?.isArchived ?? false) || (category?.isArchived ?? false)
    }

    var isImported: Bool { externalID != nil || importBatchID != nil }

    /// 是否是合并产生的那一条流水。
    var isMergeResult: Bool { mergedSourceData != nil }
}
