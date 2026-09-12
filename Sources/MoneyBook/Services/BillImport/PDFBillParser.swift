import CoreGraphics
import Foundation
import PDFKit
import Vision

/// 解析微信账单 PDF（例如把导出的 CSV 用 Excel 打开后另存为 PDF）。
///
/// 这类 PDF 的内嵌字体常常缺少可用的 ToUnicode 映射，直接抽取文本会得到乱码，
/// 因此改为渲染页面后走 Vision 文字识别，再用表格网格重建行列。
enum PDFBillParser {
    /// 渲染倍率：太低会影响识别准确率，太高会拖慢处理。
    private static let renderScale: CGFloat = 3
    private static let maximumPixelDimension: CGFloat = 4200

    static func parse(url: URL) throws -> BillParseResult {
        guard let document = PDFDocument(url: url) else { throw BillImportError.unreadableFile }
        guard document.pageCount > 0 else { throw BillImportError.noRecordsFound }

        var rows: [BillRow] = []
        var summaryLines: [String] = []
        var recognizedAnyText = false
        var lineOffset = 0

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let image = render(page: page) else { continue }

            let tokens: [BillTextToken]
            do {
                tokens = try recognizeText(in: image)
            } catch {
                throw BillImportError.pdfRecognitionFailed(error.localizedDescription)
            }
            guard !tokens.isEmpty else { continue }
            recognizedAnyText = true

            let boundaries = columnBoundaries(tokens: tokens, image: image)
            let pageRows = BillTableReconstructor.rows(from: tokens, columnBoundaries: boundaries)
            summaryLines.append(contentsOf: preambleLines(tokens: tokens))
            for var row in pageRows {
                row.sourceLine += lineOffset
                rows.append(row)
            }
            lineOffset += pageRows.count
        }

        guard recognizedAnyText else {
            throw BillImportError.pdfRecognitionFailed("没有识别到任何文字")
        }
        guard !rows.isEmpty else { throw BillImportError.noRecordsFound }
        return BillParseResult(
            platform: .wechat,
            source: .pdf,
            rows: rows,
            summary: BillSummaryParser.parse(lines: summaryLines)
        )
    }

    /// 表头之上的说明文字（含「收入：4 笔 380.00 元」这类汇总）。
    private static func preambleLines(tokens: [BillTextToken]) -> [String] {
        let headerTokens = tokens.filter {
            $0.text.contains("交易时间") || $0.text.contains("商户单号") || $0.text.contains("交易类型")
        }
        guard let headerBottom = headerTokens.map(\.minY).min() else { return [] }
        return tokens
            .filter { $0.centerY > headerBottom }
            .sorted { $0.centerY > $1.centerY }
            .map(\.text)
    }

    /// 诊断用：返回第一页的 OCR 文本块与检测到的列边界。
    static func analyze(url: URL) throws -> (tokens: [BillTextToken], boundaries: [Double]?) {
        func trace(_ message: String) {
            FileHandle.standardError.write(Data("[analyze] \(message)\n".utf8))
        }

        trace("open pdf")
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw BillImportError.unreadableFile
        }
        trace("render page")
        guard let image = render(page: page) else { throw BillImportError.unreadableFile }
        trace("render done \(image.width)x\(image.height)")
        let tokens = try recognizeText(in: image)
        trace("ocr done, \(tokens.count) tokens")
        let boundaries = columnBoundaries(tokens: tokens, image: image)
        trace("grid done, \(boundaries?.count ?? 0) lines")
        return (tokens, boundaries)
    }

    /// 诊断用：把渲染后的灰度图写成 PNG，便于人工确认位图转换是否正确。
    static func dumpGrayscale(url: URL, to outputURL: URL) throws {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            throw BillImportError.unreadableFile
        }
        guard let image = render(page: page), let gray = grayscale(from: image) else {
            throw BillImportError.unreadableFile
        }
        guard let provider = CGDataProvider(data: Data(gray.pixels) as CFData),
              let grayImage = CGImage(
                  width: gray.width,
                  height: gray.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: gray.width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { throw BillImportError.unreadableFile }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { throw BillImportError.unreadableFile }
        CGImageDestinationAddImage(destination, grayImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw BillImportError.unreadableFile }
    }

    // MARK: - 渲染与识别

    private static func render(page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        var scale = renderScale
        let longest = max(bounds.width, bounds.height) * scale
        if longest > maximumPixelDimension {
            scale = maximumPixelDimension / max(bounds.width, bounds.height)
        }

        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private static func recognizeText(in image: CGImage) throws -> [BillTextToken] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return BillTextToken(
                text: candidate.string,
                x: box.minX,
                y: box.minY,
                width: box.width,
                height: box.height
            )
        }
    }

    // MARK: - 列边界

    private static func columnBoundaries(tokens: [BillTextToken], image: CGImage) -> [Double]? {
        guard let region = tableRegion(tokens: tokens) else { return nil }
        guard let gray = grayscale(from: image) else { return nil }

        let lines = BillGridDetector.verticalLines(
            pixels: gray.pixels,
            width: gray.width,
            height: gray.height,
            region: region
        )
        // 微信账单列表是 11 列，对应 12 条竖线；数量明显不符时改用文字坐标推断。
        guard lines.count >= BillTableReconstructor.standardColumns.count else { return nil }
        return lines
    }

    /// 明细表格所在的纵向范围：从表头行的下沿到最后一行日期。
    private static func tableRegion(tokens: [BillTextToken]) -> ClosedRange<Double>? {
        let dateTokens = tokens.filter { BillTableReconstructor.parseDate($0.text) != nil }
        guard let lowest = dateTokens.map(\.minY).min() else { return nil }

        let headerTokens = tokens.filter {
            $0.text.contains("交易时间") || $0.text.contains("商户单号") || $0.text.contains("交易类型")
        }
        guard let headerBottom = headerTokens.map(\.minY).min() else {
            return max(0, lowest - 0.05)...min(1, lowest + 0.05)
        }
        guard headerBottom > lowest else { return nil }
        return max(0, lowest - 0.02)...min(1, headerBottom)
    }

    private static func grayscale(from image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)

        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? (pixels, width, height) : nil
    }
}
