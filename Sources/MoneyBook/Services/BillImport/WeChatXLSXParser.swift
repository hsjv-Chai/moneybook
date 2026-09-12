import Foundation

/// 解析微信支付账单 xlsx（新版「账单流水文件」导出）。
enum WeChatXLSXParser {
    static func parse(url: URL) throws -> (rows: [BillRow], summary: BillSummary?) {
        guard let data = try? Data(contentsOf: url) else { throw BillImportError.unreadableFile }

        let records: [[String]]
        do {
            records = try XLSXReader.firstSheetRows(from: data)
        } catch {
            throw BillImportError.spreadsheetReadFailed(error.localizedDescription)
        }

        let rows = try WeChatBillRecords.rows(from: records)
        guard !rows.isEmpty else { throw BillImportError.noRecordsFound }
        return (rows, WeChatBillRecords.summary(from: records))
    }
}
