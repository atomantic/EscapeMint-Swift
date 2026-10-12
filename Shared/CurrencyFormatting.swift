import Foundation

/// Omit an all-zero fractional part after rounding, preserving nonzero fractions
/// and locale-specific currency symbols, separators, and suffixes.
func currencyString(_ value: Double, using formatter: NumberFormatter) -> String {
    guard let text = formatter.string(from: NSNumber(value: value)) else { return "$0" }
    guard let separator = formatter.currencyDecimalSeparator,
          let range = text.range(of: separator) else { return text }
    let fraction = text[range.upperBound...].prefix(while: { $0.isNumber })
    guard !fraction.isEmpty, fraction.allSatisfy({ $0.wholeNumberValue == 0 }) else { return text }
    let end = text.index(range.upperBound, offsetBy: fraction.count)
    return text.replacingCharacters(in: range.lowerBound..<end, with: "")
}
