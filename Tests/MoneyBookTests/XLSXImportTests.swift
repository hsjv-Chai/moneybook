import Compression
import Foundation
import Testing

@testable import MoneyBook

// MARK: - 构造最小 ZIP 用于测试解压

private func littleEndian16(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
}

private func littleEndian32(_ value: Int) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}

private func deflate(_ bytes: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: max(bytes.count + 1024, 1024))
    let written = output.withUnsafeMutableBufferPointer { destination -> Int in
        bytes.withUnsafeBufferPointer { source -> Int in
            compression_encode_buffer(
                destination.baseAddress!,
                destination.count,
                source.baseAddress!,
                bytes.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    return Array(output[0..<written])
}

/// 生成一个最小可用的 ZIP（可选 Deflate），用于验证 ZIPArchive 的解析路径。
private func makeZIP(_ entries: [(name: String, data: Data, compress: Bool)]) -> Data {
    var output: [UInt8] = []
    var central: [UInt8] = []

    for entry in entries {
        let nameBytes = [UInt8](entry.name.utf8)
        let raw = [UInt8](entry.data)
        let payload = entry.compress ? deflate(raw) : raw
        let method = entry.compress ? 8 : 0
        let offset = output.count

        output += [0x50, 0x4B, 0x03, 0x04]
        output += littleEndian16(20)
        output += littleEndian16(0)
        output += littleEndian16(method)
        output += littleEndian16(0)
        output += littleEndian16(0)
        output += littleEndian32(0)
        output += littleEndian32(payload.count)
        output += littleEndian32(raw.count)
        output += littleEndian16(nameBytes.count)
        output += littleEndian16(0)
        output += nameBytes
        output += payload

        central += [0x50, 0x4B, 0x01, 0x02]
        central += littleEndian16(20)
        central += littleEndian16(20)
        central += littleEndian16(0)
        central += littleEndian16(method)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian32(0)
        central += littleEndian32(payload.count)
        central += littleEndian32(raw.count)
        central += littleEndian16(nameBytes.count)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian16(0)
        central += littleEndian32(0)
        central += littleEndian32(offset)
        central += nameBytes
    }

    let centralOffset = output.count
    output += central
    output += [0x50, 0x4B, 0x05, 0x06]
    output += littleEndian16(0)
    output += littleEndian16(0)
    output += littleEndian16(entries.count)
    output += littleEndian16(entries.count)
    output += littleEndian32(central.count)
    output += littleEndian32(centralOffset)
    output += littleEndian16(0)
    return Data(output)
}

// MARK: - 测试

@Suite("ZIP 与 xlsx 读取")
struct XLSXReaderTests {
    @Test("读取未压缩与 Deflate 压缩的条目")
    func readsZipEntries() throws {
        let stored = Data("hello".utf8)
        let deflated = Data(String(repeating: "微信支付账单", count: 50).utf8)
        let zip = makeZIP([
            (name: "stored.txt", data: stored, compress: false),
            (name: "xl/sheet1.xml", data: deflated, compress: true),
        ])

        let archive = try ZIPArchive(data: zip)
        #expect(archive.entryNames.sorted() == ["stored.txt", "xl/sheet1.xml"])
        #expect(try archive.data(for: "stored.txt") == stored)
        #expect(try archive.data(for: "xl/sheet1.xml") == deflated)
        #expect(try archive.data(for: "missing") == nil)
    }

    @Test("非 ZIP 数据会报错")
    func rejectsNonZip() {
        #expect(throws: (any Error).self) {
            _ = try ZIPArchive(data: Data("not a zip".utf8))
        }
    }

    @Test("列号解析")
    func parsesColumnReferences() {
        #expect(XLSXReader.columnIndex(from: "A1") == 0)
        #expect(XLSXReader.columnIndex(from: "K18") == 10)
        #expect(XLSXReader.columnIndex(from: "AB3") == 27)
        #expect(XLSXReader.columnIndex(from: nil) == 0)
    }

    @Test("日期格式识别")
    func detectsDateFormats() {
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("yyyy-mm-dd hh:mm:ss"))
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("mm-dd-yy"))
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("h:mm"))
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("yyyy\"年\"m\"月\"") == true)
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("¥#,##0.00") == false)
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("0.00") == false)
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("[Red]0.00") == false)
        #expect(XLSXReader.StylesDelegate.looksLikeDateFormat("General") == false)
    }

    @Test("Excel 序列号按 UTC+08:00 还原")
    func convertsSerialDate() {
        #expect(XLSXReader.formatSerialDate(46276.922627314816, uses1904Epoch: false) == "2026-09-11 22:08:35")
        #expect(XLSXReader.formatSerialDate(25569, uses1904Epoch: false) == "1970-01-01 00:00:00")
    }

    @Test("工作表 XML 解析：共享字符串、数值、日期、行号跳空")
    func parsesSheetXML() throws {
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="2" spans="1:3"><c r="A2" t="s"><v>0</v></c></row>
            <row r="5" spans="1:3">
              <c r="A5" s="1"><v>46276.922627314816</v></c>
              <c r="B5" t="s"><v>1</v></c>
              <c r="C5"><v>145</v></c>
            </row>
          </sheetData>
        </worksheet>
        """
        let rows = try XLSXReader.parseSheet(
            Data(sheet.utf8),
            sharedStrings: ["微信支付账单明细", "商户消费"],
            dateStyleIndexes: [1]
        )

        #expect(rows.count == 5)
        #expect(rows[1] == ["微信支付账单明细"])
        #expect(rows[4][0] == "2026-09-11 22:08:35")
        #expect(rows[4][1] == "商户消费")
        #expect(rows[4][2] == "145")
    }

    @Test("完整 xlsx 端到端：ZIP → 记录表 → 账单行与汇总")
    func parsesSyntheticWorkbook() throws {
        let sharedStrings = [
            "微信支付账单明细",          // 0
            "共2笔记录",                 // 1
            "收入：1笔 100.00元",        // 2
            "支出：1笔 25.80元",         // 3
            "交易时间", "交易类型", "交易对方", "商品", "收/支", "金额(元)",
            "支付方式", "当前状态", "交易单号", "商户单号", "备注",   // 4...14
            "商户消费", "某餐厅", "午餐", "支出", "零钱", "支付成功",
            "420000123420240115000000001", "MM20240115001", "/",     // 15...
            "转账", "李四", "还款", "收入", "已存入零钱",
            "420000123420240120000000003",                         // 24...
        ]

        func cell(_ reference: String, sharedString index: Int) -> String {
            "<c r=\"\(reference)\" t=\"s\"><v>\(index)</v></c>"
        }

        let headerCells = (0..<11).map { index in
            let column = String(UnicodeScalar(UInt8(65 + index)))
            return cell("\(column)2", sharedString: 4 + index)
        }.joined()

        // 表头之上是账单说明与汇总，用于校验「账单自带汇总」的解析。
        let preambleCells = [
            cell("A1", sharedString: 0),
            cell("B1", sharedString: 1),
            cell("C1", sharedString: 2),
            cell("D1", sharedString: 3),
        ].joined()

        let firstRow = """
        <row r="3" spans="1:11">
          <c r="A3" s="1"><v>45306.52425925926</v></c>
          \(cell("B3", sharedString: 15))
          \(cell("C3", sharedString: 16))
          \(cell("D3", sharedString: 17))
          \(cell("E3", sharedString: 18))
          <c r="F3" s="2"><v>25.8</v></c>
          \(cell("G3", sharedString: 19))
          \(cell("H3", sharedString: 20))
          \(cell("I3", sharedString: 21))
          \(cell("J3", sharedString: 22))
          \(cell("K3", sharedString: 23))
        </row>
        """

        let secondRow = """
        <row r="4" spans="1:11">
          <c r="A4" s="1"><v>45311.79166666667</v></c>
          \(cell("B4", sharedString: 24))
          \(cell("C4", sharedString: 25))
          \(cell("D4", sharedString: 26))
          \(cell("E4", sharedString: 27))
          <c r="F4" s="2"><v>100</v></c>
          \(cell("G4", sharedString: 23))
          \(cell("H4", sharedString: 28))
          \(cell("I4", sharedString: 29))
          \(cell("J4", sharedString: 23))
          \(cell("K4", sharedString: 23))
        </row>
        """

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1" spans="1:11">\(preambleCells)</row>
            <row r="2" spans="1:11">\(headerCells)</row>
            \(firstRow)
            \(secondRow)
          </sheetData>
        </worksheet>
        """

        let sharedStringsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)">
        \(sharedStrings.map { "<si><t>\($0)</t></si>" }.joined())
        </sst>
        """

        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <numFmts count="2">
            <numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm:ss"/>
            <numFmt numFmtId="165" formatCode="¥#,##0.00"/>
          </numFmts>
          <cellXfs count="3">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
            <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
          </cellXfs>
        </styleSheet>
        """

        let workbook = makeZIP([
            (name: "xl/workbook.xml", data: Data("<workbook/>".utf8), compress: true),
            (name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8), compress: true),
            (name: "xl/sharedStrings.xml", data: Data(sharedStringsXML.utf8), compress: true),
            (name: "xl/styles.xml", data: Data(stylesXML.utf8), compress: true),
        ])

        let records = try XLSXReader.firstSheetRows(from: workbook)
        #expect(records.count == 4)
        #expect(records[1][0] == "交易时间")

        let rows = try WeChatBillRecords.rows(from: records)
        #expect(rows.count == 2)

        let first = rows[0]
        #expect(first.transactionType == "商户消费")
        #expect(first.counterparty == "某餐厅")
        #expect(first.direction == .expense)
        #expect(first.amount == Decimal(string: "25.80"))
        #expect(first.paymentMethod == "零钱")
        #expect(first.transactionID == "420000123420240115000000001")
        #expect(first.merchantID == "MM20240115001")
        #expect(first.date != nil)
        #expect(first.issues.isEmpty)

        let second = rows[1]
        #expect(second.direction == .income)
        #expect(second.amount == Decimal(string: "100.00"))
        #expect(second.status == "已存入零钱")

        // 账单自带汇总也能从 xlsx 里读出来。
        let summary = try #require(WeChatBillRecords.summary(from: records))
        #expect(summary.totalCount == 2)
        #expect(summary.incomeTotal == Decimal(string: "100.00"))
        #expect(summary.expenseTotal == Decimal(string: "25.80"))
    }
}
