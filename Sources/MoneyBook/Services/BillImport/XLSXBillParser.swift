import Foundation

/// 解析账单 xlsx（微信「账单流水文件」等导出格式）。
enum XLSXBillParser {
    static func parse(url: URL) throws -> BillParseResult {
        guard let data = try? Data(contentsOf: url) else { throw BillImportError.unreadableFile }

        let records: [[String]]
        do {
            records = try XLSXReader.firstSheetRows(from: data)
        } catch {
            throw BillImportError.spreadsheetReadFailed(error.localizedDescription)
        }

        let rows = try BillRecords.rows(from: records)
        guard !rows.isEmpty else { throw BillImportError.noRecordsFound }
        return BillParseResult(
            platform: BillPlatform.detect(from: records),
            source: .xlsx,
            rows: rows,
            summary: BillRecords.summary(from: records)
        )
    }
}
