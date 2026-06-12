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
    private var store: FundDataStore { .shared }
    @State private var platformFilter: String? = nil
    @State private var actionFilter: FundAction? = nil
    @State private var tickerSearch: String = ""
    @State private var dateFrom: Date? = nil
    @State private var dateTo: Date? = nil

    private var allEntries: [AuditEntry] { store.auditEntries }
    private var platforms: [String] { store.platforms }

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
            let fromStr = isoDateFormatter.string(from: from)
            result = result.filter { $0.date >= fromStr }
        }
        if let to = dateTo {
            let toStr = isoDateFormatter.string(from: to)
            result = result.filter { $0.date <= toStr }
        }
        return Array(result.prefix(500))
    }

    private var stats: (buys: Double, sells: Double, dividends: Double) {
        var buys = 0.0, sells = 0.0, divs = 0.0
        for entry in filteredEntries {
            if entry.action == .BUY, let amt = entry.amount { buys += amt }
            if entry.action == .SELL, let amt = entry.amount { sells += amt }
            if let d = entry.dividend { divs += d }
        }
        return (buys, sells, divs)
    }

    private var hasActiveFilters: Bool {
        platformFilter != nil || actionFilter != nil || !tickerSearch.isEmpty || dateFrom != nil || dateTo != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
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
                #endif

                // Stats Cards
                let s = stats
                #if os(macOS)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    statsCards(s)
                }
                #else
                LazyVGrid(columns: [.init(.flexible(), spacing: 8), .init(.flexible(), spacing: 8)], spacing: 8) {
                    statsCards(s)
                }
                #endif

                // Filters
                #if os(macOS)
                macFilters
                #else
                iosFilters
                #endif

                // Entries
                if filteredEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.clipboard")
                            .font(.largeTitle).foregroundColor(.mint)
                            .accessibilityHidden(true)
                        Text("No entries found")
                            .font(.title2).fontWeight(.semibold).foregroundColor(.textPrimary)
                        Text("Adjust your filters or add entries to your funds.")
                            .font(.subheadline).foregroundColor(.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(Color.bgCard)
                    .cornerRadius(8)
                } else {
                    #if os(macOS)
                    macEntriesTable
                    #else
                    iosEntriesList
                    #endif
                }
            }
            .padding()
        }
        .background(Color.bg)
        #if os(iOS)
        .navigationTitle("Audit Trail")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Stats Cards Content

    @ViewBuilder
    private func statsCards(_ s: (buys: Double, sells: Double, dividends: Double)) -> some View {
        MetricCard(label: "Entries", value: "\(filteredEntries.count)")
        MetricCard(label: "Buys", value: formatCurrency(s.buys), color: .mint)
        MetricCard(label: "Sells", value: formatCurrency(s.sells), color: .red)
        MetricCard(label: "Net Flow", value: formatCurrency(s.buys - s.sells), color: s.buys - s.sells >= 0 ? .mint : .red)
        MetricCard(label: "Dividends", value: formatCurrency(s.dividends), color: .mint)
    }

    // MARK: - macOS Filters

    @ViewBuilder
    private var macFilters: some View {
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

            HStack(spacing: 4) {
                Text("From:").font(.caption).foregroundColor(.textMuted)
                if let from = dateFrom {
                    HStack(spacing: 2) {
                        Text(isoDateFormatter.string(from: from))
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
                        Text(isoDateFormatter.string(from: to))
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

            if hasActiveFilters {
                Button {
                    clearFilters()
                } label: {
                    Text("Clear").font(.caption).foregroundColor(.mint)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - iOS Filters

    @ViewBuilder
    private var iosFilters: some View {
        VStack(spacing: 8) {
            TextField("Search ticker...", text: $tickerSearch)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Picker("Platform", selection: $platformFilter) {
                    Text("All").tag(String?.none)
                    ForEach(platforms, id: \.self) { p in
                        Text(p.capitalized).tag(Optional(p))
                    }
                }
                .pickerStyle(.menu)

                Picker("Action", selection: $actionFilter) {
                    Text("All").tag(FundAction?.none)
                    ForEach(FundAction.allCases, id: \.self) { a in
                        Text(a.rawValue).tag(Optional(a))
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                if hasActiveFilters {
                    Button { clearFilters() } label: {
                        Text("Clear").font(.caption).foregroundColor(.mint)
                    }
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("From").font(.caption).foregroundColor(.textMuted)
                    DatePicker("", selection: Binding(
                        get: { dateFrom ?? Date() },
                        set: { dateFrom = $0 }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    if dateFrom != nil {
                        Button { dateFrom = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text("To").font(.caption).foregroundColor(.textMuted)
                    DatePicker("", selection: Binding(
                        get: { dateTo ?? Date() },
                        set: { dateTo = $0 }
                    ), displayedComponents: .date)
                    .labelsHidden()
                    if dateTo != nil {
                        Button { dateTo = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
        }
    }

    // MARK: - macOS Entries Table

    private var macEntriesTable: some View {
        VStack(spacing: 0) {
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

            ForEach(filteredEntries) { entry in
                Button {
                    NotificationCenter.default.postSelectFund(id: entry.fundId)
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

    // MARK: - iOS Entries List

    @ViewBuilder
    private var iosEntriesList: some View {
        LazyVStack(spacing: 6) {
            ForEach(filteredEntries) { entry in
                NavigationLink(destination: FundDetailView(fundId: entry.fundId)) {
                    VStack(spacing: 4) {
                        HStack {
                            Text(entry.ticker.uppercased())
                                .font(.callout).fontWeight(.semibold).foregroundColor(.mint)
                            Text(entry.platform.capitalized)
                                .font(.caption).foregroundColor(.textSecondary)
                            Spacer()
                            Text(entry.date)
                                .font(.caption).foregroundColor(.textMuted)
                        }
                        HStack {
                            if let action = entry.action {
                                Text(action.rawValue)
                                    .font(.caption).fontWeight(.medium)
                                    .foregroundColor(Color.forAction(action))
                            }
                            Text(formatCurrency(entry.value))
                                .font(.caption).foregroundColor(.textPrimary)
                            Spacer()
                            if let amt = entry.amount {
                                Text(formatCurrency(amt))
                                    .font(.caption).foregroundColor(.textSecondary)
                            }
                            if let div = entry.dividend, div > 0 {
                                Text("+\(formatCurrency(div))")
                                    .font(.caption).foregroundColor(.mint)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.bgCard)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
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
        return Text(label)
            .font(.caption.weight(.medium))
            .foregroundColor(Color.forAction(action))
            .frame(width: width, alignment: .leading)
    }

    // MARK: - Actions

    private func clearFilters() {
        platformFilter = nil
        actionFilter = nil
        tickerSearch = ""
        dateFrom = nil
        dateTo = nil
    }

}

#if DEBUG
#Preview("AuditTrail") {
    PreviewData.seedStore()
    return NavigationStack { AuditTrailView() }
}

#Preview("AuditTrail — Dark") {
    PreviewData.seedStore()
    return NavigationStack { AuditTrailView() }
        .preferredColorScheme(.dark)
}
#endif
