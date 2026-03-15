import SwiftUI

struct AuditEntry: Identifiable {
    let id: String
    let date: String
    let ticker: String
    let platform: String
    let fundId: String
    let value: Double
    let action: FundAction?
    let amount: Double?
    let dividend: Double?
    let expense: Double?
    let notes: String?
}

struct AuditTrailView: View {
    @State private var allEntries: [AuditEntry] = []
    @State private var platformFilter: String? = nil
    @State private var actionFilter: FundAction? = nil
    @State private var tickerSearch: String = ""
    @State private var platforms: [String] = []
    @State private var dateFrom: Date? = nil
    @State private var dateTo: Date? = nil
    @State private var showDateFrom = false
    @State private var showDateTo = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var filteredEntries: [AuditEntry] {
        var result = allEntries
        if let pf = platformFilter {
            result = result.filter { $0.platform == pf }
        }
        if let af = actionFilter {
            result = result.filter { $0.action == af }
        }
        if !tickerSearch.isEmpty {
            let query = tickerSearch.lowercased()
            result = result.filter { $0.ticker.lowercased().contains(query) }
        }
        if let from = dateFrom {
            let fromStr = Self.dateFormatter.string(from: from)
            result = result.filter { $0.date >= fromStr }
        }
        if let to = dateTo {
            let toStr = Self.dateFormatter.string(from: to)
            result = result.filter { $0.date <= toStr }
        }
        return Array(result.prefix(500))
    }

    private var totalBuys: Double {
        filteredEntries
            .filter { $0.action == .BUY }
            .compactMap(\.amount)
            .reduce(0, +)
    }

    private var totalSells: Double {
        filteredEntries
            .filter { $0.action == .SELL }
            .compactMap(\.amount)
            .reduce(0, +)
    }

    private var netFlow: Double {
        totalBuys - totalSells
    }

    private var totalDividends: Double {
        filteredEntries
            .compactMap(\.dividend)
            .reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audit Trail")
                            .font(.largeTitle).fontWeight(.bold).foregroundColor(.textPrimary)
                        Text("\(allEntries.count) total entries")
                            .font(.subheadline).foregroundColor(.textSecondary)
                    }
                    Spacer()
                }

                // MARK: - Stats Cards
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    statCard(title: "Total Entries", value: "\(filteredEntries.count)")
                    statCard(title: "Total Buys", value: formatCurrency(totalBuys), color: .mint)
                    statCard(title: "Total Sells", value: formatCurrency(totalSells), color: .red)
                    statCard(title: "Net Flow", value: formatCurrency(netFlow), color: netFlow >= 0 ? .mint : .red)
                    statCard(title: "Dividends", value: formatCurrency(totalDividends), color: .mint)
                }

                // MARK: - Filters
                HStack(spacing: 12) {
                    Picker("Platform", selection: $platformFilter) {
                        Text("All Platforms").tag(String?.none)
                        ForEach(platforms, id: \.self) { p in
                            Text(p).tag(Optional(p))
                        }
                    }
                    .frame(maxWidth: 180)

                    Picker("Action", selection: $actionFilter) {
                        Text("All Actions").tag(FundAction?.none)
                        ForEach(FundAction.allCases, id: \.self) { a in
                            Text(a.rawValue).tag(Optional(a))
                        }
                    }
                    .frame(maxWidth: 180)

                    TextField("Search ticker...", text: $tickerSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)

                    // Date range
                    HStack(spacing: 4) {
                        Text("From:").font(.caption).foregroundColor(.textMuted)
                        if let from = dateFrom {
                            HStack(spacing: 2) {
                                Text(Self.dateFormatter.string(from: from))
                                    .font(.caption).foregroundColor(.textSecondary)
                                Button { dateFrom = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2).foregroundColor(.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        DatePicker("", selection: Binding(
                            get: { dateFrom ?? Date() },
                            set: { dateFrom = $0 }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 30)
                    }

                    HStack(spacing: 4) {
                        Text("To:").font(.caption).foregroundColor(.textMuted)
                        if let to = dateTo {
                            HStack(spacing: 2) {
                                Text(Self.dateFormatter.string(from: to))
                                    .font(.caption).foregroundColor(.textSecondary)
                                Button { dateTo = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2).foregroundColor(.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        DatePicker("", selection: Binding(
                            get: { dateTo ?? Date() },
                            set: { dateTo = $0 }
                        ), displayedComponents: .date)
                        .labelsHidden()
                        .frame(width: 30)
                    }

                    if platformFilter != nil || actionFilter != nil || !tickerSearch.isEmpty || dateFrom != nil || dateTo != nil {
                        Button {
                            platformFilter = nil
                            actionFilter = nil
                            tickerSearch = ""
                            dateFrom = nil
                            dateTo = nil
                        } label: {
                            Text("Clear").font(.caption).foregroundColor(.mint)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 4)

                // MARK: - Table
                if filteredEntries.isEmpty {
                    VStack(spacing: 8) {
                        Text("No entries found")
                            .font(.headline)
                            .foregroundColor(.textSecondary)
                        Text("Adjust your filters or add entries to your funds.")
                            .font(.subheadline)
                            .foregroundColor(.textMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(Color.bgCard)
                    .cornerRadius(8)
                } else {
                    entriesTable
                }
            }
            .padding()
        }
        .background(Color.bg)
        .task {
            await loadEntries()
        }
    }

    // MARK: - Entries Table

    private var entriesTable: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                headerCell("Date", width: 100)
                headerCell("Fund", width: 80)
                headerCell("Platform", width: 100)
                headerCell("Value", width: 100, alignment: .trailing)
                headerCell("Action", width: 80)
                headerCell("Amount", width: 100, alignment: .trailing)
                headerCell("Dividend", width: 90, alignment: .trailing)
                headerCell("Notes", width: nil)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.bgCard.opacity(0.8))

            Divider()

            // Data rows
            ForEach(filteredEntries) { entry in
                Button {
                    NotificationCenter.default.post(name: .selectFund, object: entry.fundId)
                } label: {
                    HStack(spacing: 0) {
                        textCell(entry.date, width: 100, color: .textSecondary)
                        tickerCell(entry.ticker, width: 80)
                        textCell(entry.platform, width: 100, color: .textSecondary)
                        textCell(formatCurrency(entry.value), width: 100, alignment: .trailing)
                        actionCell(entry.action, width: 80)
                        textCell(entry.amount.map { formatCurrency($0) } ?? "-", width: 100, alignment: .trailing)
                        textCell(entry.dividend.map { formatCurrency($0) } ?? "-", width: 90, alignment: .trailing, color: entry.dividend != nil ? .mint : .textMuted)
                        textCell(entry.notes ?? "", width: nil, color: .textMuted)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color.bgCard)
                }
                .buttonStyle(.plain)

                Divider().opacity(0.5)
            }
        }
        .background(Color.bgCard)
        .cornerRadius(8)
    }

    // MARK: - Cell Helpers

    private func headerCell(_ title: String, width: CGFloat?, alignment: Alignment = .leading) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.textMuted)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func textCell(_ text: String, width: CGFloat?, alignment: Alignment = .leading, color: Color = .textPrimary) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func tickerCell(_ ticker: String, width: CGFloat) -> some View {
        Text(ticker)
            .font(.caption.weight(.semibold))
            .foregroundColor(.mint)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func actionCell(_ action: FundAction?, width: CGFloat) -> some View {
        let label = action?.rawValue ?? "-"
        let color: Color = {
            guard let a = action else { return .textMuted }
            switch a {
            case .BUY, .DEPOSIT: return .mint
            case .SELL, .WITHDRAW: return .red
            case .HOLD: return .textSecondary
            default: return .orange
            }
        }()
        return Text(label)
            .font(.caption.weight(.medium))
            .foregroundColor(color)
            .frame(width: width, alignment: .leading)
    }

    // MARK: - Stat Card

    private func statCard(title: String, value: String, color: Color = .textPrimary) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.textMuted)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.bgCard)
        .cornerRadius(8)
    }

    // MARK: - Data Loading

    private func loadEntries() async {
        let funds = await FundStore.shared.readAllFunds()
        var entries: [AuditEntry] = []
        var platformSet: Set<String> = []

        for fund in funds {
            platformSet.insert(fund.platform)
            for entry in fund.entries {
                entries.append(AuditEntry(
                    id: "\(fund.id)-\(entry.id)",
                    date: entry.date,
                    ticker: fund.ticker,
                    platform: fund.platform,
                    fundId: fund.id,
                    value: entry.value,
                    action: entry.action,
                    amount: entry.amount,
                    dividend: entry.dividend,
                    expense: entry.expense,
                    notes: entry.notes
                ))
            }
        }

        entries.sort { $0.date > $1.date }

        await MainActor.run {
            allEntries = entries
            platforms = platformSet.sorted()
        }
    }
}
