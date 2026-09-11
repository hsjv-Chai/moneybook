import Foundation

extension Decimal {
    /// 金额统一保留两位小数（四舍五入）。
    func roundedToCents(scale: Int = 2) -> Decimal {
        var input = self
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, .plain)
        return result
    }

    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }

    var absolute: Decimal { self < 0 ? -self : self }

    var isZeroAmount: Bool { self == .zero }
}
