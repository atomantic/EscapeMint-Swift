import SwiftUI
import Charts

struct FundDetailView: View {
    let fundId: String
    @State private var fund: FundData?
    @State private var showAddEntry = false
    @State private var showEditFund = false
    @State private var showEditEntry = false
    @State private var selectedEntry: FundEntry?
    @State private var showStats = true

    var body: some View {
        Group {
            if let fund {
                fundContent(fund)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bg.ignoresSafeArea())
            }
        }
        .task { await loadFund() }
        .navigationTitle(fund.map { "\($0.ticker.uppercased()) (\($0.platform))" } ?? "Fund")
        .toolbar {
            if fund != nil {
                Button("Edit") { showEditFund = true }
            }
        }
        .sheet(isPresented: $showAddEntry) {
            if let fund {
                AddEntryView(fundId: fund.id, fundType: fund.config.fund_type ?? .stock) {
                    Task { await loadFund() }
                }
            }
        }
        .sheet(isPresented: $showEditFund) {
            if let fund {
                EditFundView(fund: fund) {
                    Task { await loadFund() }
                }
            }
        }
        .sheet(isPresented: $showEditEntry) {
            if let fund, let entry = selectedEntry {
                EditEntryView(entry: entry, fundId: fund.id, fundType: fund.config.fund_type ?? .stock) {
                    Task { await loadFund() }
                }
            }
        }
    }

    @ViewBuilder
    private func fundContent(_ fund: FundData) -> some View {
        let summary = FundSummary(fund)
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
                        statsGrid(state: state, summary: summary)

                        // Charts
                        if fund.entries.count >= 3 {
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

    // MARK: - Charts (macOS - 2 columns)

    @ViewBuilder
    private func chartsGridMac(fund: FundData, summary: FundSummary) -> some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            ValueChartView(entries: fund.entries)
            PLChartView(entries: fund.entries, config: fund.config)
            APYChartView(entries: fund.entries, config: fund.config)
            if fund.entries.contains(where: { ($0.dividend ?? 0) > 0 || ($0.cash_interest ?? 0) > 0 }) {
                CapturedProfitChartView(entries: fund.entries)
            }
        }
    }

    // MARK: - Charts (iOS - stacked)

    @ViewBuilder
    private func chartsStackIOS(fund: FundData, summary: FundSummary) -> some View {
        ValueChartView(entries: fund.entries)
        PLChartView(entries: fund.entries, config: fund.config)
        APYChartView(entries: fund.entries, config: fund.config)
        if fund.entries.contains(where: { ($0.dividend ?? 0) > 0 || ($0.cash_interest ?? 0) > 0 }) {
            CapturedProfitChartView(entries: fund.entries)
        }
    }

    // MARK: - Entries Table

    @ViewBuilder
    private func entriesTable(_ fund: FundData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Entries (\(fund.entries.count))")
                .font(.headline).foregroundColor(.textPrimary)

            #if os(macOS)
            macEntriesTable(fund)
            #else
            iosEntriesList(fund)
            #endif
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func macEntriesTable(_ fund: FundData) -> some View {
        // Header
        HStack(spacing: 0) {
            Text("Date").frame(width: 85, alignment: .leading)
            Text("Action").frame(width: 60, alignment: .leading)
            Text("Value").frame(width: 80, alignment: .trailing)
            Text("Amount").frame(width: 80, alignment: .trailing)
            if fund.entries.contains(where: { $0.shares != nil }) {
                Text("Shares").frame(width: 70, alignment: .trailing)
            }
            if fund.entries.contains(where: { ($0.dividend ?? 0) > 0 }) {
                Text("Dividend").frame(width: 70, alignment: .trailing)
            }
            if fund.entries.contains(where: { $0.fund_size != nil }) {
                Text("Fund Size").frame(width: 80, alignment: .trailing)
            }
            Text("").frame(width: 30) // Edit column
        }
        .font(.caption2).fontWeight(.semibold)
        .foregroundColor(.textMuted)
        .padding(.vertical, 4)

        Divider().background(Color.bgInput)

        let hasShares = fund.entries.contains(where: { $0.shares != nil })
        let hasDividends = fund.entries.contains(where: { ($0.dividend ?? 0) > 0 })
        let hasFundSize = fund.entries.contains(where: { $0.fund_size != nil })

        ForEach(Array(fund.entries.reversed().enumerated()), id: \.offset) { _, entry in
            entryRow(entry, hasShares: hasShares, hasDividends: hasDividends, hasFundSize: hasFundSize, config: fund.config)
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: FundEntry, hasShares: Bool, hasDividends: Bool, hasFundSize: Bool, config: FundConfig) -> some View {
        HStack(spacing: 0) {
            Text(entry.date).frame(width: 85, alignment: .leading)
            Text(entry.action?.rawValue ?? "HOLD").frame(width: 60, alignment: .leading)
                .foregroundColor(actionColor(entry.action))
            Text(formatCurrency(entry.value)).frame(width: 80, alignment: .trailing)
            Text(entry.amount.map { formatCurrency($0) } ?? "").frame(width: 80, alignment: .trailing)
                .foregroundColor(.textSecondary)
            if hasShares {
                Text(entry.shares.map { String(format: "%.2f", $0) } ?? "").frame(width: 70, alignment: .trailing)
                    .foregroundColor(.textSecondary)
            }
            if hasDividends {
                Text(entry.dividend.map { formatCurrency($0) } ?? "").frame(width: 70, alignment: .trailing)
                    .foregroundColor(.mint)
            }
            if hasFundSize {
                Text(entry.fund_size.map { formatCurrency($0) } ?? "").frame(width: 80, alignment: .trailing)
                    .foregroundColor(.textSecondary)
            }
            Button {
                selectedEntry = entry
                showEditEntry = true
            } label: {
                Image(systemName: "pencil")
                    .font(.caption2).foregroundColor(.textMuted)
            }
            .buttonStyle(.plain)
            .frame(width: 30)
        }
        .font(.caption)
        .foregroundColor(.textPrimary)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func iosEntriesList(_ fund: FundData) -> some View {
        ForEach(Array(fund.entries.suffix(30).reversed().enumerated()), id: \.offset) { _, entry in
            HStack {
                Text(entry.date).font(.caption).foregroundColor(.textSecondary)
                Text(entry.action?.rawValue ?? "HOLD").font(.caption).fontWeight(.medium)
                    .foregroundColor(actionColor(entry.action))
                Spacer()
                Text(formatCurrency(entry.value)).font(.caption).foregroundColor(.textPrimary)
                if let amt = entry.amount {
                    Text(formatCurrency(amt)).font(.caption).foregroundColor(.textSecondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedEntry = entry
                showEditEntry = true
            }
        }

        if fund.entries.count > 30 {
            Text("... and \(fund.entries.count - 30) more")
                .font(.caption).foregroundColor(.textMuted)
                .frame(maxWidth: .infinity)
        }
    }

    private func actionColor(_ action: FundAction?) -> Color {
        switch action {
        case .BUY, .DEPOSIT: return .mint
        case .SELL, .WITHDRAW: return .red
        default: return .textSecondary
        }
    }

    private func loadFund() async {
        fund = await FundStore.shared.readFundById(fundId)
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

private func sampleEntries(_ entries: [FundEntry], maxPoints: Int = 60) -> [FundEntry] {
    let step = max(1, entries.count / maxPoints)
    return entries.enumerated()
        .filter { $0.offset % step == 0 || $0.offset == entries.count - 1 }
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
    let sampled = sampleEntries(entries)
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
    let sampled = sampleEntries(entries)
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
        let sampled = sampleEntries(entries)

        VStack(alignment: .leading, spacing: 8) {
            Text("Value Over Time")
                .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)

            Chart(sampled, id: \.date) { entry in
                LineMark(x: .value("Date", entry.date), y: .value("Value", entry.value))
                    .foregroundStyle(Color.mint)
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("Date", entry.date), y: .value("Value", entry.value))
                    .foregroundStyle(Color.mint.opacity(0.15))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis { emDateAxis() }
            .chartYAxis { emCurrencyAxis() }
            .frame(height: 160)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

struct PLChartView: View {
    let entries: [FundEntry]
    let config: FundConfig

    var body: some View {
        let points = computePLPoints(entries: entries, config: config)

        VStack(alignment: .leading, spacing: 8) {
            Text("P&L Over Time")
                .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)

            Chart(points) { pt in
                LineMark(x: .value("Date", pt.date), y: .value("Realized", pt.realized))
                    .foregroundStyle(by: .value("Type", "Realized"))
                LineMark(x: .value("Date", pt.date), y: .value("Liquid", pt.liquid))
                    .foregroundStyle(by: .value("Type", "Liquid"))
            }
            .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
            .chartXAxis { emDateAxis() }
            .chartYAxis { emCurrencyAxis() }
            .chartLegend(position: .top, spacing: 4)
            .frame(height: 160)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

struct APYChartView: View {
    let entries: [FundEntry]
    let config: FundConfig

    var body: some View {
        let points = computeAPYPoints(entries: entries, config: config)

        VStack(alignment: .leading, spacing: 8) {
            Text("APY Over Time")
                .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)

            Chart(points) { pt in
                LineMark(x: .value("Date", pt.date), y: .value("R.APY", pt.realizedAPY))
                    .foregroundStyle(by: .value("Type", "Realized"))
                LineMark(x: .value("Date", pt.date), y: .value("L.APY", pt.liquidAPY))
                    .foregroundStyle(by: .value("Type", "Liquid"))
            }
            .chartForegroundStyleScale(["Realized": Color.mint, "Liquid": Color.blue])
            .chartXAxis { emDateAxis() }
            .chartYAxis { emPercentAxis() }
            .chartLegend(position: .top, spacing: 4)
            .frame(height: 160)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

struct CapturedProfitChartView: View {
    let entries: [FundEntry]

    var body: some View {
        let points = computeProfitPoints(entries: entries)

        VStack(alignment: .leading, spacing: 8) {
            Text("Captured Profit")
                .font(.subheadline).fontWeight(.medium).foregroundColor(.textPrimary)

            Chart(points) { pt in
                AreaMark(x: .value("Date", pt.date), y: .value("Total", pt.total))
                    .foregroundStyle(Color.mint.opacity(0.3))
                LineMark(x: .value("Date", pt.date), y: .value("Dividends", pt.cumDividend))
                    .foregroundStyle(by: .value("Type", "Dividends"))
                LineMark(x: .value("Date", pt.date), y: .value("Interest", pt.cumInterest))
                    .foregroundStyle(by: .value("Type", "Interest"))
            }
            .chartForegroundStyleScale(["Dividends": Color.green, "Interest": Color.yellow])
            .chartXAxis { emDateAxis() }
            .chartYAxis { emCurrencyAxis() }
            .chartLegend(position: .top, spacing: 4)
            .frame(height: 160)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}

// MARK: - Chart Axis Builders

@AxisContentBuilder
private func emDateAxis() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisValueLabel {
            if let str = value.as(String.self) {
                Text(String(str.suffix(5)))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

@AxisContentBuilder
private func emCurrencyAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatCurrency(v))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}

@AxisContentBuilder
private func emPercentAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(formatPercent(v))
                    .font(.caption2).foregroundColor(.textMuted)
            }
        }
    }
}
