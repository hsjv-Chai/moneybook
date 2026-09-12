import Foundation
import SwiftData

/// 流水合并（AA 场景）：把选中的几笔收支合并成一条净额流水。
@MainActor
enum EntryMergeService {
    /// 合并后的草稿：金额由净额算出，其余字段可由用户调整。
    struct Draft {
        var date: Date
        var kind: EntryKind
        var amount: Decimal
        var category: EntryCategory?
        var account: Account?
        var note: String
    }

    enum MergeError: LocalizedError, Equatable {
        case notEnoughEntries
        case containsTransfer
        case zeroNetAmount
        case missingAccount
        case corruptedSourceData

        var errorDescription: String? {
            switch self {
            case .notEnoughEntries: "至少选择两笔流水才能合并。"
            case .containsTransfer: "转账不参与合并（它不影响收支净额），请只选择支出或收入。"
            case .zeroNetAmount: "所选流水的收支净额为 0，合并后没有金额可记。"
            case .missingAccount: "请选择这笔合并流水的账户。"
            case .corruptedSourceData: "合并前的原始记录已损坏，无法撤销。"
            }
        }
    }

    /// 净额：支出为负、收入为正、转账不计入。
    static func netAmount(of entries: [Entry]) -> Decimal {
        entries.reduce(Decimal.zero) { $0 + $1.netAmount }.roundedToCents()
    }

    static func validate(_ entries: [Entry]) throws {
        guard entries.count >= 2 else { throw MergeError.notEnoughEntries }
        if entries.contains(where: { $0.kind == .transfer }) { throw MergeError.containsTransfer }
        guard netAmount(of: entries) != 0 else { throw MergeError.zeroNetAmount }
    }

    /// 依据所选流水给出默认值：金额取净额，分类/账户取金额最大那一笔的，日期取最早一笔。
    static func draft(for entries: [Entry], defaultCategory: EntryCategory?) -> Draft {
        let net = netAmount(of: entries)
        let kind: EntryKind = net < 0 ? .expense : .income
        let amount = net.absolute
        let reference = entries.max { $0.amount < $1.amount }

        // 所有流水分类一致时直接用，否则沿用金额最大那一笔的分类。
        let categories = Set(entries.compactMap { $0.category?.uuid })
        let category: EntryCategory? = categories.count == 1
            ? entries.first?.category
            : (reference?.category ?? defaultCategory)

        let accounts = Set(entries.compactMap { $0.account?.uuid })
        let account = accounts.count == 1 ? entries.first?.account : reference?.account

        return Draft(
            date: entries.map(\.date).min() ?? Date(),
            kind: kind,
            amount: amount,
            category: category?.kind == (kind == .income ? .income : .expense) ? category : defaultCategory,
            account: account,
            note: entries.map(\.note).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        )
    }

    /// 执行合并：写入一条新流水、删除原流水，并在新流水上保留可还原的快照。
    @discardableResult
    static func merge(_ entries: [Entry], draft: Draft, context: ModelContext) throws -> Entry {
        try validate(entries)
        guard draft.amount > 0 else { throw MergeError.zeroNetAmount }
        guard let account = draft.account else { throw MergeError.missingAccount }

        let sources = entries.map(MergedEntrySource.init(entry:))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(sources)

        let merged = Entry(
            date: draft.date,
            kind: draft.kind,
            amount: draft.amount.roundedToCents(),
            category: draft.category,
            account: account,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        merged.mergedSourceData = encoded
        merged.mergedSourceCount = entries.count
        context.insert(merged)

        for entry in entries {
            context.delete(entry)
        }
        try context.save()
        return merged
    }

    /// 撤销合并：还原被合并的流水并删除合并结果，返回还原的笔数。
    @discardableResult
    static func undo(_ entry: Entry, context: ModelContext) throws -> Int {
        guard let data = entry.mergedSourceData else { throw MergeError.corruptedSourceData }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sources: [MergedEntrySource]
        do {
            sources = try decoder.decode([MergedEntrySource].self, from: data)
        } catch {
            throw MergeError.corruptedSourceData
        }
        guard !sources.isEmpty else { throw MergeError.corruptedSourceData }

        let categories = (try? context.fetch(FetchDescriptor<EntryCategory>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []

        for source in sources {
            let restored = Entry(
                date: source.date,
                kind: EntryKind(rawValue: source.kindRaw) ?? .expense,
                amount: source.amount,
                category: categories.first { $0.uuid == source.categoryUUID },
                account: accounts.first { $0.uuid == source.accountUUID },
                toAccount: accounts.first { $0.uuid == source.toAccountUUID },
                note: source.note,
                externalID: source.externalID,
                importBatchID: source.importBatchID,
                createdAt: source.createdAt
            )
            restored.updatedAt = source.updatedAt
            restored.mergedSourceData = source.mergedSourceData
            restored.mergedSourceCount = source.mergedSourceCount
            context.insert(restored)
        }

        context.delete(entry)
        try context.save()
        return sources.count
    }

    /// 合并结果里保存的来源笔数。
    static func sourceCount(of entry: Entry) -> Int {
        entry.mergedSourceCount > 0 ? entry.mergedSourceCount : decodedSources(of: entry).count
    }

    static func decodedSources(of entry: Entry) -> [MergedEntrySource] {
        guard let data = entry.mergedSourceData else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MergedEntrySource].self, from: data)) ?? []
    }

    /// 合并时被删掉的原始单号，导入去重时也要算上，避免重复导入。
    static func mergedExternalIDs(of entry: Entry) -> [String] {
        decodedSources(of: entry).compactMap(\.externalID)
    }
}
