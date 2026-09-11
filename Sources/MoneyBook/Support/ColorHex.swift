import SwiftUI

extension Color {
    /// 用 `#RRGGBB` 或 `RRGGBB` 形式的十六进制字符串构造颜色。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .gray
            return
        }

        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 应用内置的配色候选，分类与账户共用。
enum Palette {
    static let accountColors: [String] = [
        "#3478F6", "#34C759", "#FF9F0A", "#FF375F",
        "#5E5CE6", "#BF5AF2", "#64D2FF", "#8E8E93",
    ]

    static let categoryColors: [String] = [
        "#FF9F0A", "#0A84FF", "#FF375F", "#5E5CE6",
        "#BF5AF2", "#FF453A", "#64D2FF", "#30D158",
        "#FFD60A", "#8E8E93",
    ]

    static let categorySymbols: [String] = [
        "fork.knife", "car.fill", "bag.fill", "house.fill",
        "gamecontroller.fill", "cross.case.fill", "book.fill",
        "antenna.radiowaves.left.and.right", "banknote.fill", "gift.fill",
        "chart.line.uptrend.xyaxis", "doc.text.fill", "creditcard.fill",
        "airplane", "pawprint.fill", "figure.run", "cup.and.saucer.fill",
        "wineglass.fill", "tshirt.fill", "ellipsis.circle",
    ]

    static let accountSymbols: [String] = [
        "banknote", "creditcard", "creditcard.fill", "wallet.pass",
        "chart.line.uptrend.xyaxis", "building.columns", "square.grid.2x2",
    ]
}
