import Foundation
import os

// MARK: - Currency & Percent Formatters

private let currencyFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = 2
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

/// Thread-safe cache for currency formatters with non-default decimal counts.
/// `NumberFormatter` itself is thread-safe for reads after construction since iOS 7,
/// but the cache dictionary insertion is NOT — hence the lock. Callers come from both
/// the main thread (view bodies) and detached background tasks (chart computation).
private let currencyFormatterCacheLock = OSAllocatedUnfairLock(initialState: [Int: NumberFormatter]())
private func cachedCurrencyFormatter(decimals: Int, pinMinimum: Bool) -> NumberFormatter {
    let key = pinMinimum ? decimals : -(decimals + 1)
    return currencyFormatterCacheLock.withLock { cache in
        if let cached = cache[key] { return cached }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        if pinMinimum { f.minimumFractionDigits = decimals }
        f.maximumFractionDigits = decimals
        cache[key] = f
        return f
    }
}

private let percentFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .percent
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

func formatCurrency(_ value: Double, decimals: Int = 2) -> String {
    if decimals == 2 {
        return currencyString(value, using: currencyFormatter)
    }
    return currencyString(value, using: cachedCurrencyFormatter(decimals: decimals, pinMinimum: false))
}

/// Show full precision for nonzero fractions, omitting all-zero decimal places.
func formatCurrencyFull(_ value: Double, decimals: Int = 2) -> String {
    if decimals == 2 {
        return currencyString(value, using: currencyFullFormatter)
    }
    return currencyString(value, using: cachedCurrencyFormatter(decimals: decimals, pinMinimum: true))
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
