import Foundation
import SwiftData

/// 账单导入（微信支付 / 支付宝）：解析 → 预览 → 落库 → 可整批撤销。
@MainActor
enum BillImportService {
    /// 微信资金账户名。
    nonisolated static let wechatWalletName = "微信零钱"
    nonisolated static let wechatWalletChangeName = "微信零钱通"
    nonisolated static let wechatInvestmentName = "微信理财通"
    /// 支付宝资金账户名。
    nonisolated static let alipayWalletName = "支付宝余额"
    nonisolated static let alipayYuEBaoName = "余额宝"
    nonisolated static let alipayHuabeiName = "花呗"

    // MARK: - 解析

    nonisolated static func parse(url: URL) throws -> BillParseResult {
        switch url.pathExtension.lowercased() {
        case "csv", "txt":
            guard let data = try? Data(contentsOf: url) else { throw BillImportError.unreadableFile }
            guard let text = CSVText.decode(data) else { throw BillImportError.unreadableFile }
            let records = CSVText.records(from: text)
            let rows = try BillRecords.rows(from: records)
            guard !rows.isEmpty else { throw BillImportError.noRecordsFound }
            return BillParseResult(
                platform: BillPlatform.detect(from: records),
                source: .csv,
                rows: rows,
                summary: BillRecords.summary(from: records)
            )
        case "xlsx":
            return try XLSXBillParser.parse(url: url)
        case "pdf":
            return try PDFBillParser.parse(url: url)
        default: throw BillImportError.unsupportedFileType(url.pathExtension.lowercased())
        }
    }

    // MARK: - 预览

    static func makePreview(url: URL, context: ModelContext) throws -> BillImportPreview {
        let parsed = try parse(url: url)
        return try makePreview(parsed: parsed, fileName: url.lastPathComponent, context: context)
    }

    static func makePreview(
        parsed: BillParseResult,
        fileName: String,
        context: ModelContext
    ) throws -> BillImportPreview {
        let (platform, source, parsedRows, summary) = (parsed.platform, parsed.source, parsed.rows, parsed.summary)
        guard !parsedRows.isEmpty else { throw BillImportError.noRecordsFound }

        let existingEntries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let existingKeys = Set(existingEntries.compactMap(\.externalID))
        var duplicateKeys: Set<String> = []

        // 同一份账单里可能出现重复单号（历史数据或 OCR 截断），按出现次序编号；
        // 只有「数据库里已经存在」才算重复，避免同一文件内的行互相顶掉。
        var occurrences: [String: Int] = [:]
        var rows = parsedRows
        for index in rows.indices {
            let base = rows[index].deduplicationKey
            let count = (occurrences[base] ?? 0) + 1
            occurrences[base] = count
            rows[index].importKey = count == 1 ? base : "\(base)#\(count)"
        }

        var expenseTotal = Decimal.zero
        var incomeTotal = Decimal.zero
        var neutralCount = 0
        var neutralTotal = Decimal.zero
        // 与账单自带汇总比对用的是「文件本身的合计」，不受去重/跳过影响。
        var fileExpenseTotal = Decimal.zero
        var fileIncomeTotal = Decimal.zero
        var fileNeutralTotal = Decimal.zero
        var invalidCount = 0
        var refundedCount = 0
        var possibleDuplicateCount = 0
        var dates: [Date] = []
        var planCounts: [String: (count: Int, paymentMethod: String)] = [:]

        for row in rows {
            guard row.isValid, let amount = row.amount, let date = row.date else {
                invalidCount += 1
                continue
            }

            switch row.direction {
            case .income: fileIncomeTotal += amount
            case .expense: fileExpenseTotal += amount
            case .neutral, .none: fileNeutralTotal += amount
            }

            let key = row.resolvedKey
            if existingKeys.contains(key) {
                duplicateKeys.insert(key)
                continue
            }

            if row.isRefund {
                refundedCount += 1
                continue
            }

            dates.append(date)

            // 手工录入的流水没有单号，只能按「金额相同 + 时间相近」给出疑似重复提醒。
            if existingEntries.contains(where: { isLikelySameTransaction($0, row: row, date: date) }) {
                possibleDuplicateCount += 1
            }

            let needed = requiredAccounts(for: row, platform: platform)
            for name in needed.allNames {
                let existing = planCounts[name]
                planCounts[name] = (
                    count: (existing?.count ?? 0) + 1,
                    paymentMethod: existing?.paymentMethod ?? needed.label(for: name, row: row)
                )
            }

            switch row.direction {
            case .income:
                incomeTotal += amount
            case .expense:
                expenseTotal += amount
            case .neutral, .none:
                neutralCount += 1
                neutralTotal += amount
            }
        }

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let plans = planCounts
            .map { name, info in
                BillAccountPlan(
                    paymentMethod: info.paymentMethod,
                    accountName: name,
                    matchedAccountUUID: matchAccount(named: name, in: accounts)?.uuid,
                    rowCount: info.count
                )
            }
            .sorted { $0.accountName < $1.accountName }

        var warnings: [String] = []
        if invalidCount > 0 { warnings.append("\(invalidCount) 条记录缺少日期或金额，将跳过。") }
        if refundedCount > 0 { warnings.append("\(refundedCount) 条记录状态为退款/关闭/失败，默认跳过。") }
        if duplicateKeys.count > 0 { warnings.append("\(duplicateKeys.count) 条记录已经导入过，将跳过。") }
        if possibleDuplicateCount > 0 {
            warnings.append(
                "\(possibleDuplicateCount) 条记录与已有流水金额、时间相近，可能是同一笔，导入后请留意是否重复。"
            )
        }
        warnings.append(
            contentsOf: BillSummaryParser.discrepancyWarnings(
                summary: summary,
                expense: fileExpenseTotal,
                income: fileIncomeTotal,
                neutral: fileNeutralTotal,
                importedRowCount: rows.count
            )
        )

        return BillImportPreview(
            platform: platform,
            source: source,
            fileName: fileName,
            rows: rows,
            duplicateKeys: duplicateKeys,
            accountPlans: plans,
            dateRange: dates.min().flatMap { minimum in dates.max().map { minimum...$0 } },
            expenseTotal: expenseTotal.roundedToCents(),
            incomeTotal: incomeTotal.roundedToCents(),
            neutralCount: neutralCount,
            invalidCount: invalidCount,
            refundedCount: refundedCount,
            parseWarnings: warnings,
            summary: summary
        )
    }

    /// 按当前选项统计将要导入的内容，供界面显示与落库共用。
    static func selectionSummary(
        preview: BillImportPreview,
        options: BillImportOptions
    ) -> (count: Int, expense: Decimal, income: Decimal, transfer: Decimal, skipped: Int) {
        var count = 0
        var expense = Decimal.zero
        var income = Decimal.zero
        var transfer = Decimal.zero
        var skipped = 0
        var seen = preview.duplicateKeys

        for row in preview.rows {
            guard row.isValid, let amount = row.amount else {
                skipped += 1
                continue
            }
            if row.isRefund && !options.importRefundedRows {
                skipped += 1
                continue
            }
            let key = row.resolvedKey
            if options.skipDuplicates && seen.contains(key) {
                skipped += 1
                continue
            }
            seen.insert(key)

            if row.isNeutralTransaction {
                guard options.importNeutralTransactions else {
                    skipped += 1
                    continue
                }
                transfer += amount
            } else {
                switch row.direction {
                case .income: income += amount
                case .expense: expense += amount
                case .neutral, .none: transfer += amount
                }
            }
            count += 1
        }

        return (
            count: count,
            expense: expense.roundedToCents(),
            income: income.roundedToCents(),
            transfer: transfer.roundedToCents(),
            skipped: skipped
        )
    }

    // MARK: - 落库

    static func apply(
        preview: BillImportPreview,
        options: BillImportOptions,
        context: ModelContext
    ) throws -> BillImportResult {
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let categories = try context.fetch(
            FetchDescriptor<EntryCategory>(sortBy: [SortDescriptor(\.sortOrder)])
        )

        var resolved: [String: Account] = [:]
        var createdNames: [String] = []
        var nextSortOrder = (accounts.map(\.sortOrder).max() ?? 0) + 1

        func createAccount(named name: String) -> Account {
            let account = Account(
                name: name,
                kind: inferAccountKind(from: name),
                initialBalance: .zero,
                sortOrder: nextSortOrder
            )
            nextSortOrder += 1
            context.insert(account)
            createdNames.append(name)
            return account
        }

        func account(named name: String) -> Account {
            let key = normalize(name)
            if let existing = resolved[key] { return existing }

            // 用户在预览里指定了账户（含「新建」哨兵值）。
            if let chosen = options.accountOverrides[name] {
                if chosen != BillImportOptions.createNewAccountUUID,
                   let matched = accounts.first(where: { $0.uuid == chosen }) {
                    resolved[key] = matched
                    return matched
                }
                let created = createAccount(named: name)
                resolved[key] = created
                return created
            }

            if let matched = matchAccount(named: name, in: accounts) {
                resolved[key] = matched
                return matched
            }

            let created = createAccount(named: name)
            resolved[key] = created
            return created
        }

        let defaultExpenseCategory = category(
            uuid: options.defaultExpenseCategoryUUID,
            kind: .expense,
            in: categories
        )
        let defaultIncomeCategory = category(
            uuid: options.defaultIncomeCategoryUUID,
            kind: .income,
            in: categories
        )

        let batchID = UUID()
        var inserted = 0
        var skippedDuplicates = 0
        var skippedInvalid = 0
        var skippedRefunded = 0
        var expenseTotal = Decimal.zero
        var incomeTotal = Decimal.zero
        var transferTotal = Decimal.zero
        var warnings: [String] = []
        var seen = preview.duplicateKeys

        for row in preview.rows {
            guard row.isValid, let amount = row.amount, let date = row.date else {
                skippedInvalid += 1
                continue
            }
            if row.isRefund && !options.importRefundedRows {
                skippedRefunded += 1
                continue
            }

            let key = row.resolvedKey
            if options.skipDuplicates && seen.contains(key) {
                skippedDuplicates += 1
                continue
            }
            seen.insert(key)

            if row.isNeutralTransaction {
                guard options.importNeutralTransactions else {
                    skippedInvalid += 1
                    continue
                }
                let movement = transferAccounts(for: row, platform: preview.platform)
                let from = account(named: movement.from)
                let to = account(named: movement.to)
                guard from.uuid != to.uuid else {
                    warnings.append("\(row.transactionType)：转出与转入账户相同，已跳过。")
                    skippedInvalid += 1
                    continue
                }
                context.insert(
                    Entry(
                        date: date,
                        kind: .transfer,
                        amount: amount,
                        account: from,
                        toAccount: to,
                        note: note(for: row, includesType: true),
                        externalID: key,
                        importBatchID: batchID
                    )
                )
                transferTotal += amount
                inserted += 1
                continue
            }

            let direction = row.direction ?? .expense
            let targetName = primaryAccountName(for: row, platform: preview.platform)
            let target = account(named: targetName)

            let matchedCategory = BillCategorizer.suggestedCategory(
                for: row,
                direction: direction,
                categories: categories
            )
            let finalCategory = matchedCategory
                ?? (direction == .income ? defaultIncomeCategory : defaultExpenseCategory)

            context.insert(
                Entry(
                    date: date,
                    kind: direction == .income ? .income : .expense,
                    amount: amount,
                    category: finalCategory,
                    account: target,
                    note: note(for: row, includesType: false),
                    externalID: key,
                    importBatchID: batchID
                )
            )

            if direction == .income {
                incomeTotal += amount
            } else {
                expenseTotal += amount
            }
            inserted += 1
        }

        try context.save()

        return BillImportResult(
            batchID: batchID,
            inserted: inserted,
            skippedDuplicates: skippedDuplicates,
            skippedInvalid: skippedInvalid,
            skippedRefunded: skippedRefunded,
            createdAccountNames: createdNames,
            expenseTotal: expenseTotal.roundedToCents(),
            incomeTotal: incomeTotal.roundedToCents(),
            transferTotal: transferTotal.roundedToCents(),
            warnings: warnings
        )
    }

    /// 撤销一次导入：删除该批次写入的全部流水与因此新建的账户（账户仅在没有其他流水时删除）。
    static func undo(batchID: UUID, context: ModelContext) -> Int {
        let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let targets = entries.filter { $0.importBatchID == batchID }
        guard !targets.isEmpty else { return 0 }

        let touchedAccountIDs = Set(
            targets.flatMap { entry -> [UUID] in
                [entry.account?.uuid, entry.toAccount?.uuid].compactMap { $0 }
            }
        )

        for entry in targets {
            context.delete(entry)
        }
        try? context.save()

        let remaining = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        let usedAccountIDs = Set(
            remaining.flatMap { entry -> [UUID] in
                [entry.account?.uuid, entry.toAccount?.uuid].compactMap { $0 }
            }
        )
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for account in accounts where touchedAccountIDs.contains(account.uuid) && !usedAccountIDs.contains(account.uuid) {
            if account.entries.isEmpty && account.incomingTransfers.isEmpty {
                context.delete(account)
            }
        }
        try? context.save()
        return targets.count
    }

    // MARK: - 账户映射

    struct AccountMovement {
        var from: String
        var to: String
    }

    struct NeededAccounts {
        var primary: String
        var counterparty: String?
        var names: [String] { [primary, counterparty].compactMap { $0 } }
        var allNames: [String] {
            var seen: Set<String> = []
            return names.filter { seen.insert(normalize($0)).inserted }
        }

        func label(for name: String, row: BillRow) -> String {
            name == primary
                ? (row.paymentMethod.isEmpty || row.paymentMethod == "/" ? "默认账户" : row.paymentMethod)
                : "\(row.transactionType) → \(name)"
        }
    }

    /// 一条记录需要哪些账户；中性交易需要两个（转出与转入）。
    static func requiredAccounts(for row: BillRow, platform: BillPlatform) -> NeededAccounts {
        if row.isNeutralTransaction {
            let movement = transferAccounts(for: row, platform: platform)
            return NeededAccounts(primary: movement.from, counterparty: movement.to)
        }
        return NeededAccounts(primary: primaryAccountName(for: row, platform: platform), counterparty: nil)
    }

    static func primaryAccountName(for row: BillRow, platform: BillPlatform) -> String {
        accountName(forPaymentMethod: row.paymentMethod, platform: platform)
    }

    /// 中性交易的资金流向：充值/提现/信用卡还款/理财通买卖。
    static func transferAccounts(for row: BillRow, platform: BillPlatform = .wechat) -> AccountMovement {
        let wallet = platform.walletAccountName
        let paymentAccount = accountName(forPaymentMethod: row.paymentMethod, platform: platform)
        let type = row.transactionType

        if type.contains("提现") {
            return AccountMovement(from: wallet, to: paymentAccount)
        }
        if type.contains("信用卡还款") {
            return AccountMovement(from: paymentAccount, to: creditCardAccountName(from: row.counterparty))
        }
        if platform == .wechat, type.contains("理财通") {
            return type.contains("赎回")
                ? AccountMovement(from: wechatInvestmentName, to: wechatWalletName)
                : AccountMovement(from: wechatWalletName, to: wechatInvestmentName)
        }
        if platform == .wechat, type.contains("零钱通") {
            return type.contains("转出") || type.contains("取出")
                ? AccountMovement(from: wechatWalletChangeName, to: wechatWalletName)
                : AccountMovement(from: wechatWalletName, to: wechatWalletChangeName)
        }
        // 充值以及其他中性交易：资金从支付方式进入平台钱包。
        let source = paymentAccount == wallet
            ? counterpartyAccountName(for: row, platform: platform)
            : paymentAccount
        return AccountMovement(from: source, to: wallet)
    }

    /// 支付方式 → 账户名。
    /// 支付宝可能写成「账户余额&红包」这类叠加了优惠的方式，先按「&」取主支付方式。
    nonisolated static func accountName(forPaymentMethod method: String, platform: BillPlatform = .wechat) -> String {
        let tidied = tidyAccountName(method)
        let primary = tidied.split(separator: "&").first.map(String.init) ?? tidied
        let cleaned = primary.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "/" || cleaned == "-" { return platform.walletAccountName }

        switch platform {
        case .wechat:
            if cleaned.contains("零钱通") { return wechatWalletChangeName }
            if cleaned.contains("理财通") { return wechatInvestmentName }
            if cleaned.hasPrefix("零钱") { return wechatWalletName }
            return cleaned
        case .alipay:
            if cleaned.hasPrefix("账户余额") || cleaned == "余额" { return alipayWalletName }
            if cleaned.contains("余额宝") { return alipayYuEBaoName }
            if cleaned.contains("花呗") { return alipayHuabeiName }
            return cleaned
        }
    }

    private static func counterpartyAccountName(for row: BillRow, platform: BillPlatform) -> String {
        let name = tidyAccountName(row.counterparty)
        guard !name.isEmpty, name != "/" else { return platform.walletAccountName }
        return name
    }

    private static func creditCardAccountName(from counterparty: String) -> String {
        var name = tidyAccountName(counterparty)
        guard !name.isEmpty, name != "/" else { return "信用卡" }
        for suffix in ["还款", "自动还款", "信用卡自动还款"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? "信用卡" : name
    }

    /// OCR 常把中文拆得带空格或逗号，这里统一清理成紧凑名称。
    nonisolated static func tidyAccountName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in [" ", "\u{00A0}", "，", ",", "、", "。", "．", "·"] {
            name = name.replacingOccurrences(of: token, with: "")
        }
        // 全角括号统一成半角，方便与已存在的账户名比对。
        name = name
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
        return name
    }

    nonisolated static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .lowercased()
    }

    static func matchAccount(named name: String, in accounts: [Account]) -> Account? {
        let key = normalize(name)
        if let exact = accounts.first(where: { normalize($0.name) == key }) { return exact }

        // 「微信零钱」与「零钱」、「支付宝余额」与「余额」视为同一账户。
        let stripped = key
            .replacingOccurrences(of: "微信", with: "")
            .replacingOccurrences(of: "支付宝", with: "")
        guard !stripped.isEmpty else { return nil }
        return accounts.first {
            normalize($0.name)
                .replacingOccurrences(of: "微信", with: "")
                .replacingOccurrences(of: "支付宝", with: "") == stripped
        }
    }

    static func inferAccountKind(from name: String) -> AccountKind {
        if name.contains("信用卡") { return .creditCard }
        if name.contains("银行") || name.contains("储蓄卡") { return .bankCard }
        if name.contains("零钱") || name.contains("微信") || name.contains("支付宝") { return .eWallet }
        if name.contains("理财") || name.contains("基金") || name.contains("投资") { return .investment }
        if name.contains("现金") { return .cash }
        return .other
    }

    // MARK: - 辅助

    static func note(for row: BillRow, includesType: Bool) -> String {
        var parts: [String] = []
        if includesType, !row.transactionType.isEmpty { parts.append(row.transactionType) }
        if !row.counterparty.isEmpty, row.counterparty != "/" { parts.append(row.counterparty) }
        if !row.product.isEmpty, row.product != "/", row.product != row.counterparty {
            parts.append(row.product)
        }
        if !row.remark.isEmpty, row.remark != "/" { parts.append(row.remark) }
        return parts.joined(separator: " · ")
    }

    private static func existingExternalIDs(in context: ModelContext) -> Set<String> {
        let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        return Set(entries.compactMap(\.externalID))
    }

    /// 与已有手工记录相比：方向一致、金额相同、时间相差不超过一天，视为疑似同一笔。
    static func isLikelySameTransaction(_ entry: Entry, row: BillRow, date: Date) -> Bool {
        guard let amount = row.amount, entry.amount == amount else { return false }
        let kind = row.isNeutralTransaction ? EntryKind.transfer : (row.direction == .income ? .income : .expense)
        guard entry.kind == kind else { return false }
        return abs(entry.date.timeIntervalSince(date)) <= 86_400
    }

    private static func category(
        uuid: UUID?,
        kind: CategoryKind,
        in categories: [EntryCategory]
    ) -> EntryCategory? {
        if let uuid, let match = categories.first(where: { $0.uuid == uuid }) { return match }
        let fallbackName = kind == .income ? "其他收入" : "其他支出"
        return categories.first { $0.kind == kind && $0.name == fallbackName }
            ?? categories.first { $0.kind == kind }
    }
}
