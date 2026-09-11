import Foundation

/// 账单文件来源。
enum BillSource: String, Sendable {
    case csv
    case pdf

    var title: String {
        switch self {
        case .csv: "微信账单 CSV"
        case .pdf: "微信账单 PDF"
        }
    }
}

/// 微信账单里一行的收支方向。
enum BillDirection: String, Sendable {
    case expense
    case income
    case neutral

    var title: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .neutral: "中性交易"
        }
    }
}

/// 从账单中解析出的一行原始记录。
struct BillRow: Identifiable, Hashable, Sendable {
    var id: Int { sourceLine }

    var sourceLine: Int
    var rawDate: String = ""
    var date: Date?
    var transactionType: String = ""
    var counterparty: String = ""
    var product: String = ""
    var directionText: String = ""
    var amount: Decimal?
    var paymentMethod: String = ""
    var status: String = ""
    var transactionID: String = ""
    var merchantID: String = ""
    var remark: String = ""
    var issues: [String] = []

    /// 实际写入数据库的去重键：同一文件内出现重复单号时带上序号，
    /// 这样重复导入同一份文件仍能识别，同一文件里的重复行也不会互相顶掉。
    var importKey: String = ""

    /// 收/支列可能是「支出」「收入」「/」，也可能缺失。
    var direction: BillDirection? {
        let text = directionText.trimmingCharacters(in: .whitespaces)
        if text.contains("支出") { return .expense }
        if text.contains("收入") { return .income }
        if text == "/" || text.isEmpty { return isNeutralTransaction ? .neutral : nil }
        if text.contains("中性") { return .neutral }
        return nil
    }

    /// 充值、提现、信用卡还款这类不计入收支的交易。
    var isNeutralTransaction: Bool {
        let type = transactionType
        let neutralKeywords = ["充值", "提现", "信用卡还款", "理财通", "零钱通", "转入", "转出", "还款"]
        return neutralKeywords.contains { type.contains($0) }
    }

    var isRefund: Bool {
        let refundKeywords = ["已退款", "已全额退款", "退款成功", "对方已退还", "已退还", "已撤销", "交易关闭", "已关闭", "失败"]
        return refundKeywords.contains { status.contains($0) }
    }

    /// 展示用标题：优先商品名，其次是交易对方。
    var displayTitle: String {
        if !product.isEmpty, product != "/" { return product }
        if !counterparty.isEmpty, counterparty != "/" { return counterparty }
        return transactionType
    }

    var isValid: Bool {
        date != nil && amount != nil && (amount ?? .zero) > 0
    }

    /// 去重使用的稳定标识；PDF 解析拿不到单号时退化为内容指纹。
    var deduplicationKey: String {
        let trimmedID = transactionID.trimmingCharacters(in: .whitespaces)
        if !trimmedID.isEmpty {
            return "wechat:\(trimmedID)"
        }
        let stamp = date.map { String(Int($0.timeIntervalSince1970)) } ?? rawDate
        return "wechat-fallback:\(stamp)|\(amount.map { "\($0)" } ?? "")|\(transactionType)|\(counterparty)|\(product)"
    }

    /// 入库时实际使用的键。
    var resolvedKey: String { importKey.isEmpty ? deduplicationKey : importKey }
}

/// 一个支付方式对应的账户处理方案。
struct BillAccountPlan: Identifiable, Hashable, Sendable {
    var id: String { paymentMethod }

    var paymentMethod: String
    var accountName: String
    /// 已有账户时给出其标识；为空表示需要新建。
    var matchedAccountUUID: UUID?
    var rowCount: Int

    var willCreateAccount: Bool { matchedAccountUUID == nil }
}

/// 导入前的预览结果。
/// 账单自带的汇总信息，用于交叉校验解析结果。
struct BillSummary: Sendable, Equatable {
    var totalCount: Int?
    var incomeCount: Int?
    var incomeTotal: Decimal?
    var expenseCount: Int?
    var expenseTotal: Decimal?
    var neutralCount: Int?
    var neutralTotal: Decimal?

    var isEmpty: Bool {
        totalCount == nil && incomeTotal == nil && expenseTotal == nil && neutralTotal == nil
    }
}

/// 导入前的预览结果。
struct BillImportPreview: Sendable {
    var source: BillSource
    var fileName: String
    var rows: [BillRow]
    var duplicateKeys: Set<String>
    var accountPlans: [BillAccountPlan]
    var dateRange: ClosedRange<Date>?
    var expenseTotal: Decimal
    var incomeTotal: Decimal
    var neutralCount: Int
    var invalidCount: Int
    var refundedCount: Int
    var parseWarnings: [String]
    var summary: BillSummary?

    var validRows: [BillRow] { rows.filter(\.isValid) }
}

/// 用户可调的导入选项。
struct BillImportOptions: Sendable {
    var defaultExpenseCategoryUUID: UUID?
    var defaultIncomeCategoryUUID: UUID?
    /// 中性交易（充值/提现/信用卡还款等）会作为账户间转账导入。
    var importNeutralTransactions = true
    /// 退款/关闭/失败的记录默认不导入。
    var importRefundedRows = false
    /// 已存在同单号的记录默认跳过。
    var skipDuplicates = true
    /// 支付方式 → 账户；为空时按计划自动匹配或新建。
    var accountOverrides: [String: UUID] = [:]

    /// 用户在「账户对应」里选择「新建」时写入的哨兵值。
    static let createNewAccountUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
}

/// 导入执行结果。
struct BillImportResult: Sendable {
    var batchID: UUID
    var inserted: Int
    var skippedDuplicates: Int
    var skippedInvalid: Int
    var skippedRefunded: Int
    var createdAccountNames: [String]
    var expenseTotal: Decimal
    var incomeTotal: Decimal
    var transferTotal: Decimal
    var warnings: [String] = []
}

enum BillImportError: LocalizedError, Equatable {
    case unreadableFile
    case unsupportedFileType(String)
    case noRecordsFound
    case pdfRecognitionFailed(String)
    case nothingToImport

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "无法读取该文件，请确认文件没有损坏。"
        case .unsupportedFileType(let ext):
            "暂不支持 .\(ext) 文件。请导入微信导出的 CSV，或由账单生成的 PDF。"
        case .noRecordsFound:
            "没有在文件里找到账单明细，请确认这是微信支付账单。"
        case .pdfRecognitionFailed(let reason):
            "PDF 文字识别失败：\(reason)"
        case .nothingToImport:
            "没有可导入的记录。"
        }
    }
}
