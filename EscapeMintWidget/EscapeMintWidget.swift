import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct EscapeMintTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry() -> PortfolioEntry {
        guard let snapshot = readSnapshot() else {
            return PortfolioEntry.placeholder
        }
        return PortfolioEntry(
            date: snapshot.updatedAt,
            totalValue: snapshot.totalValue,
            totalGainUsd: snapshot.totalGainUsd,
            totalGainPct: snapshot.totalGainPct,
            activeFunds: snapshot.activeFunds,
            actionableCount: snapshot.actionableCount,
            topFunds: snapshot.topFunds,
            isPlaceholder: false
        )
    }

    private func readSnapshot() -> WidgetSnapshotData? {
        let appGroupId = "group.net.shadowpuppet.EscapeMint"
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let fileURL = containerURL.appendingPathComponent("widget-snapshot.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
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
    let isPlaceholder: Bool

    static let placeholder = PortfolioEntry(
        date: Date(),
        totalValue: 12345.67,
        totalGainUsd: 1234.56,
        totalGainPct: 11.1,
        activeFunds: 5,
        actionableCount: 2,
        topFunds: [
            WidgetFundData(ticker: "BTC", platform: "Coinbase", value: 5000, gainPct: 15.2, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 150),
            WidgetFundData(ticker: "TQQQ", platform: "Robinhood", value: 3000, gainPct: 8.5, isDueForAction: false, recommendedAction: nil, recommendedAmount: nil),
            WidgetFundData(ticker: "SPXL", platform: "Robinhood", value: 2500, gainPct: 5.3, isDueForAction: true, recommendedAction: "BUY", recommendedAmount: 100),
        ],
        isPlaceholder: true
    )
}

// MARK: - Shared data (mirrors main app types, decoded from JSON)

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

// MARK: - Widget Views

struct SmallWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "leaf.fill")
                    .foregroundColor(.mint)
                    .font(.caption)
                Text("EscapeMint")
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(formatCurrency(entry.totalValue))
                .font(.title2).fontWeight(.bold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: entry.totalGainPct >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2)
                Text(String(format: "%.1f%%", entry.totalGainPct))
                    .font(.caption).fontWeight(.medium)
            }
            .foregroundColor(entry.totalGainPct >= 0 ? .green : .red)

            if entry.actionableCount > 0 {
                Text("\(entry.actionableCount) action\(entry.actionableCount == 1 ? "" : "s") due")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }
}

struct MediumWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        HStack(spacing: 12) {
            // Left: portfolio summary
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "leaf.fill")
                        .foregroundColor(.mint)
                        .font(.caption)
                    Text("EscapeMint")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(formatCurrency(entry.totalValue))
                    .font(.title2).fontWeight(.bold)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: entry.totalGainPct >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text(String(format: "%.1f%%", entry.totalGainPct))
                        .font(.caption).fontWeight(.medium)
                }
                .foregroundColor(entry.totalGainPct >= 0 ? .green : .red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Right: top funds
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
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }
}

struct LargeWidgetView: View {
    let entry: PortfolioEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "leaf.fill")
                    .foregroundColor(.mint)
                Text("EscapeMint")
                    .font(.headline).fontWeight(.semibold)
                Spacer()
                if entry.actionableCount > 0 {
                    Text("\(entry.actionableCount) due")
                        .font(.caption).fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.orange).cornerRadius(8)
                }
            }

            // Portfolio value
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

            // Fund list
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
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }
}

// MARK: - Currency Formatter

private func formatCurrency(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
    return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
}

// MARK: - Widget Configuration

struct EscapeMintWidget: Widget {
    let kind: String = "EscapeMintWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EscapeMintTimelineProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, macOSApplicationExtension 14.0, *) {
                    widgetContent(for: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                } else {
                    widgetContent(for: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Portfolio")
        .description("Track your portfolio value and DCA actions.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }

    @ViewBuilder
    private func widgetContent(for entry: PortfolioEntry) -> some View {
        // Use a ViewThatFits approach via environment
        WidgetContentView(entry: entry)
    }
}

struct WidgetContentView: View {
    let entry: PortfolioEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
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
