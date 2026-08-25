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
        guard let snapshot = WidgetSnapshotTransport.readSnapshot() else { return .noData }
        return PortfolioEntry(snapshot: snapshot)
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
    let topFunds: [WidgetFundSnapshot]
    let state: EntryState

    enum EntryState {
        case loaded
        case noData
        case placeholder
    }

    init(snapshot: WidgetSnapshot) {
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
            WidgetFundSnapshot(ticker: "BTC", platform: "Coinbase", value: 5000, gainPct: 15.2, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 150),
            WidgetFundSnapshot(ticker: "TQQQ", platform: "Robinhood", value: 3000, gainPct: 8.5, isDueForAction: false, recommendedAction: nil, recommendedAmount: nil),
            WidgetFundSnapshot(ticker: "SPXL", platform: "Robinhood", value: 2500, gainPct: 5.3, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 100),
            WidgetFundSnapshot(ticker: "CASH", platform: "Robinhood", value: 2000, gainPct: 3.2, isDueForAction: false, recommendedAction: nil, recommendedAmount: nil),
            WidgetFundSnapshot(ticker: "ETH", platform: "Coinbase", value: 1500, gainPct: -2.1, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 75),
        ] : []
        self.state = state
    }

    static let placeholder = PortfolioEntry(state: .placeholder)
    static let noData = PortfolioEntry(state: .noData)
}

// WidgetSnapshot and WidgetFundSnapshot are defined in Shared/WidgetSnapshotModels.swift

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
    var font: Font = .caption
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "leaf.fill")
                .foregroundColor(.mint)
                .font(.subheadline)
            Text("EscapeMint")
                .font(font).fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
    }
}

private struct GainChangeView: View {
    let pct: Double
    var font: Font = .subheadline
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption)
            Text(String(format: "%.1f%%", pct))
                .font(font).fontWeight(.medium)
        }
        .foregroundColor(pct >= 0 ? .green : .red)
    }
}

// Compact currency formatting is provided by formatWidgetCurrency in
// Shared/WidgetSnapshotModels.swift (shared with the main app target).

// MARK: - Widget Views

struct SmallWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        Group {
            if entry.state == .noData {
                WidgetEmptyState()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "leaf.fill")
                            .foregroundColor(.mint)
                            .font(.caption2)
                        if entry.actionableCount > 0 {
                            Spacer()
                            Text("\(entry.actionableCount) due")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundColor(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(formatWidgetCurrency(entry.totalValue))
                        .font(.system(size: 34, weight: .bold))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    HStack(spacing: 3) {
                        Image(systemName: entry.totalGainPct >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text(String(format: "%.1f%%", entry.totalGainPct))
                            .font(.subheadline).fontWeight(.medium)
                    }
                    .foregroundColor(entry.totalGainPct >= 0 ? .green : .red)
                    Spacer(minLength: 0)
                    Text("\(entry.activeFunds) fund\(entry.activeFunds == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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
                        Text(formatWidgetCurrency(entry.totalValue))
                            .font(.title).fontWeight(.bold)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        GainChangeView(pct: entry.totalGainPct)
                        if entry.actionableCount > 0 {
                            Text("\(entry.actionableCount) action\(entry.actionableCount == 1 ? "" : "s") due")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.topFunds.prefix(3).enumerated()), id: \.offset) { _, fund in
                            HStack {
                                Text(fund.ticker)
                                    .font(.subheadline).fontWeight(.semibold)
                                Spacer()
                                Text(formatWidgetCurrency(fund.value))
                                    .font(.caption)
                                Text(String(format: "%+.1f%%", fund.gainPct))
                                    .font(.caption)
                                    .foregroundColor(fund.gainPct >= 0 ? .green : .red)
                            }
                        }
                        if entry.topFunds.isEmpty {
                            Text("No funds yet")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        WidgetBranding(font: .subheadline)
                        Spacer()
                        if entry.actionableCount > 0 {
                            Text("\(entry.actionableCount) due")
                                .font(.subheadline).fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.orange).cornerRadius(8)
                        }
                    }

                    Text(formatWidgetCurrency(entry.totalValue))
                        .font(.largeTitle).fontWeight(.bold)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: entry.totalGainPct >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline)
                        Text(formatWidgetCurrency(abs(entry.totalGainUsd)))
                            .font(.title3)
                        Text(String(format: "(%+.1f%%)", entry.totalGainPct))
                            .font(.title3)
                    }
                    .foregroundColor(entry.totalGainPct >= 0 ? .green : .red)

                    Divider()

                    ForEach(Array(entry.topFunds.prefix(7).enumerated()), id: \.offset) { _, fund in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fund.ticker)
                                    .font(.body).fontWeight(.semibold)
                                Text(fund.platform)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(formatWidgetCurrency(fund.value))
                                    .font(.body)
                                Text(String(format: "%+.1f%%", fund.gainPct))
                                    .font(.caption)
                                    .foregroundColor(fund.gainPct >= 0 ? .green : .red)
                            }
                            if fund.isDueForAction, let action = fund.recommendedAction {
                                Text(action)
                                    .font(.caption).fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(action == "BUY" ? Color.green : action == "SELL" ? Color.red : Color.gray)
                                    .cornerRadius(4)
                            }
                        }
                    }

                    if entry.topFunds.isEmpty {
                        Spacer()
                        Text("Open the app to add funds")
                            .font(.body).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        Spacer(minLength: 0)
                        HStack {
                            Text("\(entry.activeFunds) fund\(entry.activeFunds == 1 ? "" : "s")")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(entry.date, style: .relative)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
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
