import Foundation

// MARK: - Currency & Percent Formatters

private let currencyFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    return f
}()

private let currencyFullFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

private let percentFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

func formatCurrency(_ value: Double) -> String {
    currencyFormatter.maximumFractionDigits = 2
    return currencyFormatter.string(from: NSNumber(value: value)) ?? "$0.00"
}

/// Always show cents (2 decimal places) regardless of magnitude
func formatCurrencyFull(_ value: Double) -> String {
    currencyFullFormatter.string(from: NSNumber(value: value)) ?? "$0.00"
}

func formatPercent(_ value: Double) -> String {
    percentFormatter.string(from: NSNumber(value: value)) ?? "0%"
}

func formatPercentCompact(_ value: Double) -> String {
    let pct = value * 100
    let absPct = abs(pct)
    let sign = pct < 0 ? "-" : ""
    if absPct >= 10 {
        return "\(sign)\(String(format: "%.0f", absPct))%"
    }
    return "\(sign)\(String(format: "%.1f", absPct))%"
}

func formatCurrencyCompact(_ value: Double) -> String {
    let absValue = abs(value)
    let sign = value < 0 ? "-" : ""
    if absValue >= 1_000_000 {
        return "\(sign)$\(String(format: "%.1f", absValue / 1_000_000))M"
    } else if absValue >= 1000 {
        return "\(sign)$\(String(format: "%.1f", absValue / 1000))K"
    } else {
        return "\(sign)$\(String(format: "%.0f", absValue))"
    }
}

func formatPercentSigned(_ value: Double) -> String {
    let pct = value * 100
    if pct >= 10_000 { return "+10,000%+" }
    if pct <= -10_000 { return "-10,000%+" }
    let sign = pct >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", pct))%"
}
