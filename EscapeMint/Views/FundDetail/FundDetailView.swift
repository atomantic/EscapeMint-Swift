import SwiftUI
import Charts

struct FundDetailView: View {
    let fundId: String
    private var store: FundDataStore { .shared }
    @State private var showAddEntry = false
    @State private var showEditFund = false
    @State private var showEditEntry = false
    @State private var selectedEntry: FundEntry?
    @State private var selectedEntryIndex: Int?
    @State private var visibleColumns: Set<String> = []
    @State private var showColumnConfig = false
    @State private var showStats = true
    @State private var derivPoints: [DerivativesChartPoint]?

    private var fund: FundData? { store.fund(byId: fundId) }
    private var summary: FundSummary? { store.summary(byId: fundId) }

    var body: some View {
        Group {
            if let fund, let summary {
                fundContent(fund, summary: summary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bg.ignoresSafeArea())
            }
        }
        .navigationTitle(fund.map { "\($0.ticker.uppercased()) (\($0.platform))" } ?? "Fund")
        .toolbar {
            if fund != nil {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showEditFund = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #endif
            }
        }
        .sheet(isPresented: $showAddEntry) {
            if let fund {
                AddEntryView(fundId: fund.id, fundType: fund.config.fund_type ?? .stock) {
                    Task { await store.reload() }
                }
            }
        }
        .sheet(isPresented: $showEditFund) {
            if let fund {
                EditFundView(fund: fund, onSaved: {
                    Task { await store.reload() }
                }, onDeleted: {
                    NotificationCenter.default.post(name: .selectDashboard, object: nil)
                })
            }
        }
        .sheet(isPresented: $showEditEntry) {
            if let fund, let entry = selectedEntry, let entryIndex = selectedEntryIndex {
                EditEntryView(entry: entry, entryIndex: entryIndex, fundId: fund.id, fundType: fund.config.fund_type ?? .stock) {
                    Task { await store.reload() }
                }
            }
        }
    }

    @ViewBuilder
    private func fundContent(_ fund: FundData, summary: FundSummary) -> some View {
        let state = summary.state
        let rec = summary.recommendation
        let features = summary.features

        ScrollView {
            VStack(spacing: 12) {
                // Breadcrumb (macOS)
                #if os(macOS)
                HStack(spacing: 4) {
                    Text("Dashboard").font(.caption).foregroundColor(.mint)
                    Text("/").font(.caption).foregroundColor(.textMuted)
                    Text(fund.platform.capitalized).font(.caption).foregroundColor(.mint)
                    Text("/").font(.caption).foregroundColor(.textMuted)
                    Text(fund.ticker.uppercased()).font(.caption).foregroundColor(.textPrimary).fontWeight(.medium)
                    Spacer()
                    Button { showEditFund = true } label: {
                        Label("Edit Fund", systemImage: "gearshape")
                            .font(.callout).fontWeight(.medium)
                            .foregroundColor(.textSecondary)
                    }
                    .buttonStyle(.plain)
                    Button { showAddEntry = true } label: {
                        Label("Take Action", systemImage: "plus.circle.fill")
                            .font(.callout).fontWeight(.medium)
                            .foregroundColor(.mint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 4)
                #endif

                // Config summary
                configSummary(fund, features: features, state: state)

                // Recommendation
                if let rec {
                    recommendationCard(rec)
                }

                // Collapsible Stats section
                DisclosureGroup(isExpanded: $showStats) {
                    VStack(spacing: 12) {
                        if summary.closedMetrics == nil {
                            statsGrid(state: state, summary: summary)
                        }

                        // Charts (closed fund state card flows inside the grid for derivatives)
                        if fund.entries.count >= 3 || summary.closedMetrics != nil {
                            #if os(macOS)
                            chartsGridMac(fund: fund, summary: summary)
                            #else
                            chartsStackIOS(fund: fund, summary: summary)
                            #endif
                        }
                    }
                } label: {
                    Text("Stats & Charts")
                        .font(.headline).foregroundColor(.textPrimary)
                }
                .tint(.textSecondary)
                .task(id: fund.id) {
                    if fund.config.fund_type == .derivatives {
                        derivPoints = computeDerivativesChartData(entries: fund.entries, config: fund.config)
                    } else {
                        derivPoints = nil
                    }
                }

                // Entries table
                entriesTable(fund)
            }
            .padding()
            #if os(iOS)
            .padding(.bottom, 80)
            #endif
        }
        .background(Color.bg.ignoresSafeArea())
        #if os(iOS)
        .overlay(alignment: .bottom) {
            Button { showAddEntry = true } label: {
                Label("Take Action", systemImage: "plus.circle.fill")
                    .font(.callout).fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.mint)
                    .cornerRadius(20)
            }
            .padding(.bottom, 16)
        }
        #endif
    }

    // MARK: - Config Summary

    @ViewBuilder
    private func configSummary(_ fund: FundData, features: FundTypeFeatures, state: FundState) -> some View {
        let config = fund.config
        HStack(spacing: 8) {
            Text(features.label)
                .fontWeight(.medium)
            if let cat = config.category, let catInfo = categoryConfig[cat] {
                Text(catInfo.shortLabel)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.forCategory(cat).opacity(0.2))
                    .cornerRadius(4)
            }
            if config.status == .closed {
                Text("Closed")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.bgInput).cornerRadius(4)
            }
            if let acc = config.accumulate {
                Text(acc ? "Accumulate" : "Harvest")
                    .foregroundColor(acc ? .mint : .orange)
            }
            if !isCashFund(config.fund_type) {
                Text("\(formatPercent(config.target_apy ?? 0)) target")
                Text("\(config.interval_days ?? 7)d")
                if let min = config.input_min_usd, let mid = config.input_mid_usd, let max = config.input_max_usd {
                    Text("$\(Int(min))/\(Int(mid))/\(Int(max))")
                }
            }
            Spacer()
            if config.status == .closed, let lastCash = fund.entries.last?.cash {
                Text("Cash: \(formatCurrency(lastCash))")
                    .fontWeight(.medium)
            }
            Text("Size: \(formatCurrency(config.fund_size_usd ?? 0))")
                .fontWeight(.medium)
        }
        .font(.caption)
        .foregroundColor(.textMuted)
        .padding(8)
        .background(Color.bgCard)
        .cornerRadius(8)
    }

    // MARK: - Recommendation Card

    @ViewBuilder
    private func recommendationCard(_ rec: Recommendation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(rec.action.rawValue) \(formatCurrency(rec.amount))")
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(rec.action == .BUY ? .mint : rec.action == .SELL ? .red : .yellow)
                Text(rec.reasoning)
                    .font(.caption).foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.bgCard)
        .overlay(
            Rectangle()
                .fill(rec.action == .BUY ? Color.mint : rec.action == .SELL ? Color.red : Color.yellow)
                .frame(width: 4),
            alignment: .leading
        )
        .cornerRadius(12)
    }

    // MARK: - Stats Grid

    @ViewBuilder
    private func statsGrid(state: FundState, summary: FundSummary) -> some View {
        #if os(macOS)
        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 4), spacing: 8) {
            statBoxes(state: state, summary: summary)
        }
        #else
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
            statBoxes(state: state, summary: summary)
        }
        #endif
    }

    @ViewBuilder
    private func statBoxes(state: FundState, summary: FundSummary) -> some View {
        StatBox(label: "Invested", value: formatCurrency(state.startInputUsd))
        StatBox(label: "Asset Value", value: formatCurrency(summary.currentValue), color: summary.currentValue >= state.startInputUsd ? .mint : .red)
        StatBox(label: "Unrealized", value: "\(state.gainUsd >= 0 ? "+" : "")\(formatCurrency(state.gainUsd))", color: state.gainUsd >= 0 ? .mint : .red)
        StatBox(label: "Realized", value: formatCurrency(state.realizedGainsUsd), color: state.realizedGainsUsd > 0 ? .mint : .white)
        StatBox(label: "Realized APY", value: formatPercent(summary.realizedAPY), color: summary.realizedAPY > 0 ? .mint : .red)
        StatBox(label: "Liquid P&L", value: formatCurrency(summary.liquidGain), color: summary.liquidGain >= 0 ? .mint : .red)
        StatBox(label: "Liquid APY", value: formatPercent(summary.liquidAPY), color: summary.liquidAPY > 0 ? .mint : .red)
        StatBox(label: "Cash", value: formatCurrency(state.cashAvailableUsd))
    }

    // MARK: - Charts

    @ViewBuilder
    private func derivativesChartContent() -> some View {
        // iOS: stacked layout with Current State card at top
        if let cm = summary?.closedMetrics {
            ClosedFundStateCard(closedMetrics: cm)
        }
        if let pts = derivPoints, let fund {
            let cb = fund.config.chart_bounds
            DerivativesPLChart(points: pts, fundId: fund.id, bounds: cb?["pnl"])
            DerivativesAPYChart(points: pts, fundId: fund.id, bounds: cb?["apy"])
            DerivativesValueChart(points: pts)
            DerivativesPriceChart(points: pts, fundId: fund.id, bounds: cb?["derivativesPrice"])
            DerivativesMarginChart(points: pts)
            DerivativesCapturedProfitChart(points: pts)
        } else {
            ProgressView().frame(height: 160)
        }
    }

    @ViewBuilder
    private func standardChartContent(fund: FundData) -> some View {
        ValueChartView(entries: fund.entries)
        PLChartView(entries: fund.entries, config: fund.config)
        APYChartView(entries: fund.entries, config: fund.config)
        if fund.entries.contains(where: { ($0.dividend ?? 0) > 0 || ($0.cash_interest ?? 0) > 0 }) {
            CapturedProfitChartView(entries: fund.entries)
        }
    }

    // MARK: - Charts (macOS - 2 columns)

    @ViewBuilder
    private func chartsGridMac(fund: FundData, summary: FundSummary) -> some View {
        if fund.config.fund_type == .derivatives {
            // First row: 3 columns (Current State + P&L + APY)
            let cb = fund.config.chart_bounds
            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                if let cm = summary.closedMetrics {
                    ClosedFundStateCard(closedMetrics: cm)
                }
                if let pts = derivPoints {
                    DerivativesPLChart(points: pts, fundId: fund.id, bounds: cb?["pnl"])
                    DerivativesAPYChart(points: pts, fundId: fund.id, bounds: cb?["apy"])
                }
            }
            // Remaining rows: 2 columns
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                if let pts = derivPoints {
                    DerivativesValueChart(points: pts)
                    DerivativesPriceChart(points: pts, fundId: fund.id, bounds: cb?["derivativesPrice"])
                    DerivativesMarginChart(points: pts)
                    DerivativesCapturedProfitChart(points: pts)
                }
            }
        } else {
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                standardChartContent(fund: fund)
            }
        }
    }

    // MARK: - Charts (iOS - stacked)

    @ViewBuilder
    private func chartsStackIOS(fund: FundData, summary: FundSummary) -> some View {
        if fund.config.fund_type == .derivatives {
            derivativesChartContent()
        } else {
            standardChartContent(fund: fund)
        }
    }

    // MARK: - Entries Table

    private static let allEntryColumns: [(id: String, label: String, defaultVisible: Bool, excludeFrom: Set<FundType>)] = [
        ("date", "Date", true, []),
        ("action", "Action", true, []),
        ("value", "Value", true, []),
        ("amount", "Amount", true, []),
        ("shares", "Shares", true, [.cash, .derivatives]),
        ("price", "Price", true, [.cash]),
        ("dividend", "Dividend", true, [.crypto, .derivatives, .cash]),
        ("expense", "Expense", false, []),
        ("cash_interest", "Interest", false, []),
        ("fund_size", "Fund Size", true, []),
        ("cash", "Cash", false, []),
        ("margin_available", "Margin Avail", false, [.crypto]),
        ("margin_borrowed", "Margin Borrowed", false, [.crypto]),
        ("notes", "Notes", false, []),
        ("contracts", "Contracts", false, [.cash, .stock, .crypto]),
        ("entry_price", "Avg Entry", false, [.cash, .stock, .crypto]),
        ("fee", "Fee", false, [.cash, .stock, .crypto]),
        ("margin_locked", "Margin Locked", false, [.cash, .stock, .crypto]),
        ("liquidation_price", "Liq Price", false, [.cash, .stock, .crypto]),
        ("unrealized_pnl", "Unrealized", false, [.cash, .stock, .crypto]),
    ]

    private func availableColumns(for fundType: FundType?) -> [(id: String, label: String)] {
        let ft = fundType ?? .stock
        return Self.allEntryColumns
            .filter { !$0.excludeFrom.contains(ft) }
            .map { (id: $0.id, label: $0.label) }
    }

    private func defaultVisibleColumns(for fundType: FundType?) -> Set<String> {
        let ft = fundType ?? .stock
        var cols = Set(Self.allEntryColumns
            .filter { $0.defaultVisible && !$0.excludeFrom.contains(ft) }
            .map(\.id))
        if ft == .derivatives {
            cols.formUnion(["contracts", "price", "entry_price", "fee", "cash", "margin_locked", "liquidation_price", "unrealized_pnl"])
        }
        return cols
    }

    private func initVisibleColumnsIfNeeded(for fund: FundData) {
        if visibleColumns.isEmpty {
            visibleColumns = defaultVisibleColumns(for: fund.config.fund_type)
        }
    }

    @ViewBuilder
    private func entriesTable(_ fund: FundData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Entries (\(fund.entries.count))")
                    .font(.headline).foregroundColor(.textPrimary)
                Spacer()
                #if os(macOS)
                Button {
                    showColumnConfig.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout).foregroundColor(.mint)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showColumnConfig) {
                    columnConfigPopover(fund)
                }
                #else
                Button {
                    showColumnConfig = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout).foregroundColor(.mint)
                }
                .sheet(isPresented: $showColumnConfig) {
                    columnConfigSheet(fund)
                }
                #endif
            }

            #if os(macOS)
            macEntriesTable(fund)
            #else
            iosEntriesList(fund)
            #endif
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .onAppear { initVisibleColumnsIfNeeded(for: fund) }
    }

    #if os(macOS)
    @ViewBuilder
    private func columnConfigPopover(_ fund: FundData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Columns")
                .font(.caption).fontWeight(.semibold).foregroundColor(.textMuted)
                .padding(.bottom, 4)
            ForEach(availableColumns(for: fund.config.fund_type), id: \.id) { col in
                Toggle(col.label, isOn: Binding(
                    get: { visibleColumns.contains(col.id) },
                    set: { on in
                        if on { visibleColumns.insert(col.id) }
                        else { visibleColumns.remove(col.id) }
                    }
                ))
                .font(.caption)
                .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .frame(minWidth: 180)
    }
    #endif

    @ViewBuilder
    private func columnConfigSheet(_ fund: FundData) -> some View {
        NavigationStack {
            List {
                ForEach(availableColumns(for: fund.config.fund_type), id: \.id) { col in
                    Toggle(col.label, isOn: Binding(
                        get: { visibleColumns.contains(col.id) },
                        set: { on in
                            if on { visibleColumns.insert(col.id) }
                            else { visibleColumns.remove(col.id) }
                        }
                    ))
                }
            }
            .navigationTitle("Columns")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showColumnConfig = false }
                }
            }
        }
    }

    private func columnWidth(_ id: String) -> CGFloat {
        switch id {
        case "date": return 85
        case "action": return 60
        case "notes": return 120
        default: return 80
        }
    }

    private func columnAlignment(_ id: String) -> Alignment {
        switch id {
        case "date", "action", "notes": return .leading
        default: return .trailing
        }
    }

    @ViewBuilder
    private func macEntriesTable(_ fund: FundData) -> some View {
        let cols = availableColumns(for: fund.config.fund_type).filter { visibleColumns.contains($0.id) }

        // Header
        HStack(spacing: 0) {
            ForEach(cols, id: \.id) { col in
                Text(col.label)
                    .frame(width: columnWidth(col.id), alignment: columnAlignment(col.id))
            }
            Text("").frame(width: 30) // Edit column
        }
        .font(.caption2).fontWeight(.semibold)
        .foregroundColor(.textMuted)
        .padding(.vertical, 4)

        Divider().background(Color.bgInput)

        let count = fund.entries.count

        ForEach(Array(fund.entries.reversed().enumerated()), id: \.offset) { reverseIdx, entry in
            let actualIndex = count - 1 - reverseIdx
            entryRow(entry, entryIndex: actualIndex, columns: cols, config: fund.config, isEven: reverseIdx.isMultiple(of: 2))
        }
    }

    @ViewBuilder
    private func entryCell(_ entry: FundEntry, columnId: String) -> some View {
        switch columnId {
        case "date":
            Text(entry.date)
        case "action":
            Text(entry.action?.rawValue ?? "HOLD")
                .foregroundColor(Color.forAction(entry.action))
        case "value":
            Text(formatCurrency(entry.value))
        case "amount":
            Text(entry.amount.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "shares":
            Text(entry.shares.map { String(format: "%.4f", $0) } ?? "")
                .foregroundColor(.textSecondary)
        case "price":
            Text(entry.price.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "dividend":
            Text(entry.dividend.map { formatCurrency($0) } ?? "")
                .foregroundColor(.mint)
        case "expense":
            Text(entry.expense.map { formatCurrency($0) } ?? "")
                .foregroundColor(.red)
        case "cash_interest":
            Text(entry.cash_interest.map { formatCurrency($0) } ?? "")
                .foregroundColor(.mint)
        case "fund_size":
            Text(entry.fund_size.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "cash":
            Text(entry.cash.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "margin_available":
            Text(entry.margin_available.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "margin_borrowed":
            Text(entry.margin_borrowed.map { formatCurrency($0) } ?? "")
                .foregroundColor(.orange)
        case "notes":
            Text(entry.notes ?? "")
                .foregroundColor(.textMuted)
                .lineLimit(1)
        case "contracts":
            Text(entry.contracts.map { String(format: "%.2f", $0) } ?? "")
                .foregroundColor(.textSecondary)
        case "entry_price":
            Text(entry.entry_price.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "fee":
            Text(entry.fee.map { formatCurrency($0) } ?? "")
                .foregroundColor(.red)
        case "margin_locked":
            Text(entry.margin_locked.map { formatCurrency($0) } ?? "")
                .foregroundColor(.orange)
        case "liquidation_price":
            Text(entry.liquidation_price.map { formatCurrency($0) } ?? "")
                .foregroundColor(.textSecondary)
        case "unrealized_pnl":
            Text(entry.unrealized_pnl.map { formatCurrency($0) } ?? "")
                .foregroundColor((entry.unrealized_pnl ?? 0) >= 0 ? .mint : .red)
        default:
            Text("")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: FundEntry, entryIndex: Int, columns: [(id: String, label: String)], config: FundConfig, isEven: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.id) { col in
                entryCell(entry, columnId: col.id)
                    .frame(width: columnWidth(col.id), alignment: columnAlignment(col.id))
            }
            Button {
                selectedEntry = entry
                selectedEntryIndex = entryIndex
                showEditEntry = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 30)
        }
        .font(.caption)
        .foregroundColor(.textPrimary)
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(isEven ? Color.clear : Color.textPrimary.opacity(0.04))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func iosEntriesList(_ fund: FundData) -> some View {
        ForEach(Array(fund.entries.suffix(30).reversed().enumerated()), id: \.offset) { reverseIdx, entry in
            let actualIndex = fund.entries.count - 1 - reverseIdx
            HStack {
                Text(entry.date).font(.caption).foregroundColor(.textSecondary)
                Text(entry.action?.rawValue ?? "HOLD").font(.caption).fontWeight(.medium)
                    .foregroundColor(Color.forAction(entry.action))
                Spacer()
                Text(formatCurrency(entry.value)).font(.caption).foregroundColor(.textPrimary)
                if let amt = entry.amount {
                    Text(formatCurrency(amt)).font(.caption).foregroundColor(.textSecondary)
                        .frame(width: 70, alignment: .trailing)
                }
                Image(systemName: "ellipsis.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(reverseIdx.isMultiple(of: 2) ? Color.clear : Color.textPrimary.opacity(0.04))
            .cornerRadius(6)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedEntry = entry
                selectedEntryIndex = actualIndex
                showEditEntry = true
            }
        }

        if fund.entries.count > 30 {
            Text("... and \(fund.entries.count - 30) more")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity)
        }
    }

}

// MARK: - Stat Box

struct StatBox: View {
    let label: String
    let value: String
    var color: Color = .textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.semibold).foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.bgCard)
        .cornerRadius(8)
    }
}

// MARK: - Charts

func sampleArray<T>(_ items: [T], maxPoints: Int = 60) -> [T] {
    let step = max(1, items.count / maxPoints)
    return items.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == items.count - 1 }
        .map(\.element)
}

// MARK: - Chart Data Point Structs

private struct PLPoint: Identifiable {
    let id: String
    let date: String
    let realized: Double
    let liquid: Double
}

private struct APYPoint: Identifiable {
    let id: String
    let date: String
    let realizedAPY: Double
    let liquidAPY: Double
}

private struct ProfitPoint: Identifiable {
    let id: String
    let date: String
    let cumDividend: Double
    let cumInterest: Double
    var total: Double { cumDividend + cumInterest }
}

private func computePLPoints(entries: [FundEntry], config: FundConfig) -> [PLPoint] {
    let sampled = sampleArray(entries)
    return sampled.map { entry in
        let prior = entries.filter { $0.date <= entry.date }
        let trades = entriesToTrades(prior)
        let cashflows = entriesToCashFlows(prior)
        let dividends = entriesToDividends(prior)
        let expenses = entriesToExpenses(prior)
        let state = computeFundState(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: entry.value, asOfDate: entry.date)
        return PLPoint(id: entry.date, date: entry.date, realized: state.realizedGainsUsd, liquid: state.gainUsd + state.realizedGainsUsd)
    }
}

private func computeAPYPoints(entries: [FundEntry], config: FundConfig) -> [APYPoint] {
    let sampled = sampleArray(entries)
    return sampled.map { entry in
        let prior = entries.filter { $0.date <= entry.date }
        let trades = entriesToTrades(prior)
        let cashflows = entriesToCashFlows(prior)
        let dividends = entriesToDividends(prior)
        let expenses = entriesToExpenses(prior)
        let startDate = getFundStartDate(prior)
        let days = max(1, daysBetween(startDate, entry.date))
        let state = computeFundState(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: entry.value, asOfDate: entry.date)
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: startDate, asOfDate: entry.date)
        let basis = twfs > 0 ? twfs : state.startInputUsd
        let rAPY = computeLinearAPY(state.realizedGainsUsd, basis, days)
        let lGain = state.gainUsd + state.realizedGainsUsd
        let lAPY = computeLinearAPY(lGain, basis, days)
        return APYPoint(id: entry.date, date: entry.date, realizedAPY: rAPY, liquidAPY: lAPY)
    }
}

private func computeProfitPoints(entries: [FundEntry]) -> [ProfitPoint] {
    // Accumulate over ALL entries first, then sample — avoids missing values from skipped entries
    var cumD = 0.0
    var cumI = 0.0
    let all = entries.map { entry -> ProfitPoint in
        cumD += entry.dividend ?? 0
        cumI += entry.cash_interest ?? 0
        return ProfitPoint(id: entry.date, date: entry.date, cumDividend: cumD, cumInterest: cumI)
    }
    let step = max(1, all.count / 60)
    return all.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == all.count - 1 }
        .map(\.element)
}

struct ValueChartView: View {
    let entries: [FundEntry]

    var body: some View {
        let sampled = sampleArray(entries)

        EMChartCard(title: "Value Over Time") {
            if let last = sampled.last {
                LegendDot(color: .mint, label: formatCurrency(last.value))
            }
        } chart: {
            Chart(sampled, id: \.date) { entry in
                let d = isoDateFormatter.date(from: entry.date) ?? Date()
                AreaMark(x: .value("Date", d), y: .value("Value", entry.value))
                    .foregroundStyle(Color.mint.opacity(0.15))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Date", d), y: .value("Value", entry.value))
                    .foregroundStyle(Color.mint)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis { emDateAxisTemporal() }
            .chartYAxis { emCurrencyAxis() }
            .frame(height: 160)
        }
    }
}

struct PLChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    @State private var points: [PLPoint]?

    var body: some View {
        EMChartCard(title: "P&L Over Time") {
            if let last = points?.last {
                LegendDot(color: .mint, label: "R: \(formatCurrency(last.realized))")
                LegendDot(color: .blue, label: "L: \(formatCurrency(last.liquid))")
            }
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realized < 0 || $0.liquid < 0 }
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        AreaMark(x: .value("Date", d), y: .value("Liquid", pt.liquid))
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.linear)
                        LineMark(x: .value("Date", d), y: .value("Realized", pt.realized))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("Liquid", pt.liquid))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emCurrencyAxis() }
                .chartLegend(.hidden)
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
        .task { points = computePLPoints(entries: entries, config: config) }
    }
}

struct APYChartView: View {
    let entries: [FundEntry]
    let config: FundConfig
    @State private var points: [APYPoint]?

    var body: some View {
        EMChartCard(title: "APY Over Time") {
            if let last = points?.last {
                LegendDot(color: .mint, label: "R: \(formatPercent(last.realizedAPY))")
                LegendDot(color: .blue, label: "L: \(formatPercent(last.liquidAPY))")
            }
        } chart: {
            if let points {
                let hasNegative = points.contains { $0.realizedAPY < 0 || $0.liquidAPY < 0 }
                Chart {
                    ForEach(points) { pt in
                        let d = isoDateFormatter.date(from: pt.date) ?? Date()
                        AreaMark(x: .value("Date", d), y: .value("L.APY", pt.liquidAPY))
                            .foregroundStyle(Color.blue.opacity(0.1))
                            .interpolationMethod(.linear)
                        LineMark(x: .value("Date", d), y: .value("R.APY", pt.realizedAPY))
                            .foregroundStyle(by: .value("Type", "Realized"))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Date", d), y: .value("L.APY", pt.liquidAPY))
                            .foregroundStyle(by: .value("Type", "Liquid"))
                            .interpolationMethod(.monotone)
                    }
                    if hasNegative { emZeroLine() }
                }
                .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
                .chartXAxis { emDateAxisTemporal() }
                .chartYAxis { emPercentAxis() }
                .chartLegend(.hidden)
                .frame(height: 160)
            } else {
                ProgressView().frame(height: 160)
            }
        }
        .task { points = computeAPYPoints(entries: entries, config: config) }
    }
}

struct CapturedProfitChartView: View {
    let entries: [FundEntry]

    var body: some View {
        let points = computeProfitPoints(entries: entries)

        EMChartCard(title: "Captured Profit") {
            if let last = points.last {
                LegendDot(color: .green, label: "Div: \(formatCurrency(last.cumDividend))")
                LegendDot(color: .yellow, label: "Int: \(formatCurrency(last.cumInterest))")
            }
        } chart: {
            Chart(points) { pt in
                let d = isoDateFormatter.date(from: pt.date) ?? Date()
                AreaMark(x: .value("Date", d), y: .value("Total", pt.total))
                    .foregroundStyle(Color.mint.opacity(0.15))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Date", d), y: .value("Dividends", pt.cumDividend))
                    .foregroundStyle(by: .value("Type", "Dividends"))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", d), y: .value("Interest", pt.cumInterest))
                    .foregroundStyle(by: .value("Type", "Interest"))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(["Dividends": Color.green, "Interest": Color.yellow])
            .chartXAxis { emDateAxisTemporal() }
            .chartYAxis { emCurrencyAxis() }
            .chartLegend(.hidden)
            .frame(height: 160)
        }
    }
}

// MARK: - Chart Axis Builders
// Date formatters (isoDateFormatter, shortDateFormatter) and format helpers
// (formatDateLabel, formatTooltipDate) are in Converters.swift

@AxisContentBuilder
func emDateAxisTemporal() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisValueLabel {
            if let date = value.as(Date.self) {
                Text(shortDateFormatter.string(from: date))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

@AxisContentBuilder
func emCurrencyAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatCurrencyCompact(v))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

@AxisContentBuilder
func emPercentAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatPercent(v))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

// MARK: - Zero Reference Line

@ChartContentBuilder
func emZeroLine() -> some ChartContent {
    RuleMark(y: .value("Zero", 0))
        .foregroundStyle(Color.textMuted.opacity(0.4))
        .lineStyle(StrokeStyle(dash: [4, 4]))
}

