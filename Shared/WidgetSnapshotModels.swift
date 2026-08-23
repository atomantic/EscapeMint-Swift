import Foundation

/// App Group identifiers shared by the main app and widget extension. Keep the
/// access-state key here so the extension can fail closed without depending on
/// main-target-only `AppStorageKeys`.
enum WidgetSharedStorage {
    static let appGroupId = "group.net.shadowpuppet.EscapeMint"
    static let snapshotFileName = "widget-snapshot.json"
    static let externalPortfolioLockedKey = "escapemint-external-portfolio-locked"
}

// MARK: - Shared Widget Snapshot Models
//
// Single source of truth for the data written by WidgetDataProvider (main app)
// and read by EscapeMintTimelineProvider (widget extension).
//
// JSON wire format: default synthesized CodingKeys (camelCase field names).
// Do NOT rename fields without migrating stored snapshots in the App Group container.

struct WidgetSnapshot: Codable {
    let totalValue: Double
    let totalGainUsd: Double
    let totalGainPct: Double
    let activeFunds: Int
    let actionableCount: Int
    let topFunds: [WidgetFundSnapshot]
    let updatedAt: Date
}

struct WidgetFundSnapshot: Codable {
    let ticker: String
    let platform: String
    let value: Double
    let gainPct: Double
    let isDueForAction: Bool
    let recommendedAction: String?
    let recommendedAmount: Double?
}

// MARK: - Widget Currency Formatter
//
// Compact currency display for space-constrained widget surfaces.
// Values >= $1,000 are shown without cents ($1,234); smaller values show cents ($9.99).
// Uses NumberFormatter (not the K/M suffix approach in app's formatCurrencyCompact)
// to preserve the locale-correct currency symbol and thousands separator.
//
// NumberFormatter is documented as thread-safe for reads after initial construction.
// Formatters are module-private statics so they are initialised once at first use.

private let _widgetCurrencyFormatterFull: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = 2
    return f
}()

private let _widgetCurrencyFormatterCompact: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = 0
    return f
}()

/// Format a dollar amount for compact widget display.
/// - Values ≥ $1,000 drop the cents for brevity (e.g. "$1,234").
/// - Values < $1,000 keep two decimal places (e.g. "$9.99").
func formatWidgetCurrency(_ value: Double) -> String {
    let formatter = value >= 1000 ? _widgetCurrencyFormatterCompact : _widgetCurrencyFormatterFull
    return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
}
