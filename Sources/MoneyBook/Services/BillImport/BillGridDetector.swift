import Foundation

/// 从渲染后的位图里找出表格的竖直分隔线，用来确定列边界。
///
/// 相比用文字块坐标聚类，网格线不受 OCR 合并单元格的影响。
enum BillGridDetector {
    /// 每一列中深色像素的占比，用于诊断与阈值调参。
    static func columnCoverage(
        pixels: [UInt8],
        width: Int,
        height: Int,
        region: ClosedRange<Double>,
        darkness: UInt8 = 235
    ) -> [Double] {
        guard width > 0, height > 0, pixels.count >= width * height else { return [] }
        guard let rows = rowRange(region: region, height: height) else { return [] }

        var counts = [Int](repeating: 0, count: width)
        for row in rows {
            let base = row * width
            for column in 0..<width where pixels[base + column] < darkness {
                counts[column] += 1
            }
        }
        let total = Double(rows.count)
        return counts.map { Double($0) / total }
    }

    private static func rowRange(region: ClosedRange<Double>, height: Int) -> Range<Int>? {
        let topRow = Int((1 - region.upperBound) * Double(height))
        let bottomRow = Int((1 - region.lowerBound) * Double(height))
        let startRow = max(0, min(topRow, bottomRow))
        let endRow = min(height - 1, max(topRow, bottomRow))
        guard endRow > startRow else { return nil }
        return startRow..<(endRow + 1)
    }

    /// - Parameters:
    ///   - pixels: 灰度像素，0 为黑、255 为白，行优先排列。
    ///   - region: 只统计该纵向区间（归一化，原点在左下角）内的像素。
    /// - Returns: 检测到的竖直分隔线归一化 x 坐标（升序）。
    static func verticalLines(
        pixels: [UInt8],
        width: Int,
        height: Int,
        region: ClosedRange<Double>,
        darkness: UInt8 = 235,
        coverageThreshold: Double = 0.6
    ) -> [Double] {
        guard width > 0, height > 0, pixels.count >= width * height else { return [] }
        // 归一化 y（原点左下）→ 位图行号（原点左上）。
        guard let rows = rowRange(region: region, height: height) else { return [] }

        var darkCounts = [Int](repeating: 0, count: width)

        for row in rows {
            let base = row * width
            for column in 0..<width where pixels[base + column] < darkness {
                darkCounts[column] += 1
            }
        }

        let minimumDark = Int(Double(rows.count) * coverageThreshold)
        var lines: [Double] = []
        var runStart: Int?

        for column in 0..<width {
            if darkCounts[column] >= minimumDark {
                if runStart == nil { runStart = column }
            } else if let start = runStart {
                lines.append(center(start: start, end: column - 1, width: width))
                runStart = nil
            }
        }
        if let start = runStart {
            lines.append(center(start: start, end: width - 1, width: width))
        }

        // 过滤掉过窄的表格（至少要有 3 条线才可能是表格）。
        guard lines.count >= 3 else { return [] }

        // 相邻线太近时只保留较粗的一条。
        var merged: [Double] = []
        for line in lines where merged.last.map({ line - $0 > 0.01 }) ?? true {
            merged.append(line)
        }
        return merged
    }

    private static func center(start: Int, end: Int, width: Int) -> Double {
        (Double(start) + Double(end)) / 2 / Double(width)
    }
}
