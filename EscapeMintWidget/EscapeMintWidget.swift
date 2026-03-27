import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct EscapeMintTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadEntry() -> PortfolioEntry {
        guard let snapshot = readSnapshot() else { return .noData }
        return PortfolioEntry(snapshot: snapshot)
    }

    // Must match WidgetDataProvider.appGroupId and .snapshotFileName in main app
    private static let appGroupId = "group.net.shadowpuppet.EscapeMint"
    private static let snapshotFileName = "widget-snapshot.json"

    private func readSnapshot() -> WidgetSnapshotData? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) else { return nil }
        guard let data = try? Data(contentsOf: url.appendingPathComponent(Self.snapshotFileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshotData.self, from: data)
    }
}

// MARK: - Widget Entry

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let totalValue: Double
    let totalGainUsd: Double
    let totalGainPct: Double
    let activeFunds: Int
    let actionableCount: Int
    let topFunds: [WidgetFundData]
    let state: EntryState

    enum EntryState {
        case loaded    // Real data from App Group snapshot
        case noData    // No snapshot available — show empty state
        case placeholder // System placeholder — show redacted preview
    }

    init(snapshot: WidgetSnapshotData) {
        self.date = snapshot.updatedAt
        self.totalValue = snapshot.totalValue
        self.totalGainUsd = snapshot.totalGainUsd
        self.totalGainPct = snapshot.totalGainPct
        self.activeFunds = snapshot.activeFunds
        self.actionableCount = snapshot.actionableCount
        self.topFunds = snapshot.topFunds
        self.state = .loaded
    }

    private init(state: EntryState) {
        self.date = Date()
        self.totalValue = state == .placeholder ? 12345.67 : 0
        self.totalGainUsd = state == .placeholder ? 1234.56 : 0
        self.totalGainPct = state == .placeholder ? 11.1 : 0
        self.activeFunds = state == .placeholder ? 5 : 0
        self.actionableCount = state == .placeholder ? 2 : 0
        self.topFunds = state == .placeholder ? [
            WidgetFundData(ticker: "BTC", platform: "Coinbase", value: 5000, gainPct: 15.2, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 150),
            WidgetFundData(ticker: "TQQQ", platform: "Robinhood", value: 3000, gainPct: 8.5, isDueForAction: false, recommendedAction: nil, recommendedAmount: nil),
            WidgetFundData(ticker: "SPXL", platform: "Robinhood", value: 2500, gainPct: 5.3, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 100),
        ] : []
        self.state = state
    }

    static let placeholder = PortfolioEntry(state: .placeholder)
    static let noData = PortfolioEntry(state: .noData)
}

// MARK: - Shared Data (field names must match WidgetSnapshot/WidgetFundSnapshot in main app)

struct WidgetSnapshotData: Codable {
    let totalValue: Double
    let totalGainUsd: Double
    let totalGainPct: Double
    let activeFunds: Int
    let actionableCount: Int
    let topFunds: [WidgetFundData]
    let updatedAt: Date
}

struct WidgetFundData: Codable {
    let ticker: String
    let platform: String
    let value: Double
    let gainPct: Double
    let isDueForAction: Bool
    let recommendedAction: String?
    let recommendedAmount: Double?
}

// MARK: - Empty State View

private struct WidgetEmptyState: View {
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(spacing: family == .systemSmall ? 8 : 12) {
            Image(systemName: "leaf.fill")
                .font(family == .systemSmall ? .title3 : .title2)
                .foregroundColor(.mint)
            Text("EscapeMint")
                .font(family == .systemSmall ? .caption : .callout)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Text("Open the app to\nload your portfolio")
                .font(family == .systemSmall ? .caption2 : .caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared Components

private struct WidgetBranding: View {
    var font: Font = .caption2
    var body: some View {
        HStack {
            Image(systemName: "leaf.fill")
                .foregroundColor(.mint)
                .font(.caption)
            Text("EscapeMint")
                .font(font).fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
    }
}

private struct GainChangeView: View {
    let pct: Double
    var font: Font = .caption
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2)
            Text(String(format: "%.1f%%", pct))
                .font(font).fontWeight(.medium)
        }
        .foregroundColor(pct >= 0 ? .green : .red)
    }
}

// MARK: - Currency Formatter (cached)

private let currencyFormatterFull: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = 2
    return f
}()

private let currencyFormatterCompact: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.maximumFractionDigits = 0
    return f
}()

private func formatCurrency(_ value: Double) -> String {
    let formatter = value >= 1000 ? currencyFormatterCompact : currencyFormatterFull
    return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
}

// MARK: - Widget Views

struct SmallWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        Group {
            if entry.state == .noData {
                WidgetEmptyState()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetBranding()
                    Spacer()
                    Text(formatCurrency(entry.totalValue))
                        .font(.title2).fontWeight(.bold)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    GainChangeView(pct: entry.totalGainPct)
                    if entry.actionableCount > 0 {
                        Text("\(entry.actionableCount) action\(entry.actionableCount == 1 ? "" : "s") due")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .padding()
                .redacted(reason: entry.state == .placeholder ? .placeholder : [])
            }
        }
    }
}

struct MediumWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        Group {
            if entry.state == .noData {
                WidgetEmptyState()
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        WidgetBranding()
                        Spacer()
                        Text(formatCurrency(entry.totalValue))
                            .font(.title2).fontWeight(.bold)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        GainChangeView(pct: entry.totalGainPct)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entry.topFunds.prefix(3).enumerated()), id: \.offset) { _, fund in
                            HStack {
                                Text(fund.ticker)
                                    .font(.caption).fontWeight(.semibold)
                                Spacer()
                                Text(formatCurrency(fund.value))
                                    .font(.caption2)
                                Text(String(format: "%+.1f%%", fund.gainPct))
                                    .font(.caption2)
                                    .foregroundColor(fund.gainPct >= 0 ? .green : .red)
                            }
                        }
                        if entry.topFunds.isEmpty {
                            Text("No funds yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .redacted(reason: entry.state == .placeholder ? .placeholder : [])
            }
        }
    }
}

struct LargeWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        Group {
            if entry.state == .noData {
                WidgetEmptyState()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        WidgetBranding(font: .headline)
                        Spacer()
                        if entry.actionableCount > 0 {
                            Text("\(entry.actionableCount) due")
                                .font(.caption).fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.orange).cornerRadius(8)
                        }
                    }

                    Text(formatCurrency(entry.totalValue))
                        .font(.title).fontWeight(.bold)
                    HStack(spacing: 4) {
                        Image(systemName: entry.totalGainPct >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption)
                        Text(formatCurrency(abs(entry.totalGainUsd)))
                            .font(.subheadline)
                        Text(String(format: "(%+.1f%%)", entry.totalGainPct))
                            .font(.subheadline)
                    }
                    .foregroundColor(entry.totalGainPct >= 0 ? .green : .red)

                    Divider()

                    ForEach(Array(entry.topFunds.prefix(5).enumerated()), id: \.offset) { _, fund in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fund.ticker)
                                    .font(.callout).fontWeight(.semibold)
                                Text(fund.platform)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(formatCurrency(fund.value))
                                    .font(.callout)
                                Text(String(format: "%+.1f%%", fund.gainPct))
                                    .font(.caption2)
                                    .foregroundColor(fund.gainPct >= 0 ? .green : .red)
                            }
                            if fund.isDueForAction, let action = fund.recommendedAction {
                                Text(action)
                                    .font(.caption2).fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(action == "BUY" ? Color.green : action == "SELL" ? Color.red : Color.gray)
                                    .cornerRadius(4)
                            }
                        }
                    }

                    if entry.topFunds.isEmpty {
                        Spacer()
                        Text("Open the app to add funds")
                            .font(.callout).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .padding()
                .redacted(reason: entry.state == .placeholder ? .placeholder : [])
            }
        }
    }
}

// MARK: - Widget Configuration

struct EscapeMintWidget: Widget {
    let kind: String = "EscapeMintWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EscapeMintTimelineProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, macOSApplicationExtension 14.0, *) {
                    WidgetContentView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    WidgetContentView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Portfolio")
        .description("Track your portfolio value and DCA actions.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WidgetContentView: View {
    let entry: PortfolioEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        case .systemLarge: LargeWidgetView(entry: entry)
        default: SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Widget Bundle

@main
struct EscapeMintWidgetBundle: WidgetBundle {
    var body: some Widget {
        EscapeMintWidget()
    }
}
