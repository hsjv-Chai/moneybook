import Foundation

/// 被合并掉的原始流水快照。
///
/// 合并是破坏性操作（原流水会被删除），把快照存在合并结果上，
/// 就能在任何时候（包括重启之后）把原流水还原回来。
struct MergedEntrySource: Codable, Sendable, Equatable {
    var date: Date
    var kindRaw: String
    var amount: Decimal
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var categoryUUID: UUID?
    var accountUUID: UUID?
    var toAccountUUID: UUID?
    var externalID: String?
    var importBatchID: UUID?
    /// 被合并的记录本身也可能是合并结果，这里保留它的快照以便完整还原。
    var mergedSourceData: Data?
    var mergedSourceCount: Int

    init(entry: Entry) {
        date = entry.date
        kindRaw = entry.kindRaw
        amount = entry.amount
        note = entry.note
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        categoryUUID = entry.category?.uuid
        accountUUID = entry.account?.uuid
        toAccountUUID = entry.toAccount?.uuid
        externalID = entry.externalID
        importBatchID = entry.importBatchID
        mergedSourceData = entry.mergedSourceData
        mergedSourceCount = entry.mergedSourceCount
    }
}
