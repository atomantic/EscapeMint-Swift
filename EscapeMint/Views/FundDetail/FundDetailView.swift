import SwiftUI
import Charts

struct FundDetailView: View {
    let fundId: String
    @State private var fund: FundData?
    @State private var showAddEntry = false
    @State private var showEditFund = false

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
    }

    @ViewBuilder
    private func fundContent(_ fund: FundData) -> some View {
        let today = todayString()
        let trades = entriesToTrades(fund.entries)
        let cashflows = entriesToCashFlows(fund.entries)
        let dividends = entriesToDividends(fund.entries)
        let expenses = entriesToExpenses(fund.entries)
        let value = getLatestValue(fund.entries)
        let startDate = getFundStartDate(fund.entries)
        let days = max(1, daysBetween(startDate, today))

        let state = computeFundState(config: fund.config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: value, asOfDate: today)
        let rec = computeRecommendation(config: fund.config, state: state)
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: startDate, asOfDate: today)
        let realizedAPY = computeRealizedAPY(state.realizedGainsUsd, twfs > 0 ? twfs : state.startInputUsd, days)
        let liquidGain = state.gainUsd + state.realizedGainsUsd
        let liquidAPY = computeRealizedAPY(liquidGain, twfs > 0 ? twfs : state.startInputUsd, days)
        let features = getFeatures(fund.config.fund_type)

        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 12) {
                    // Config summary
                    HStack {
                        Text(features.label)
                        if fund.config.status == .closed { Text("· Closed") }
                        if !isCashFund(fund.config.fund_type) {
                            Text("· \(formatPercent(fund.config.target_apy ?? 0)) target")
                            Text("· \(fund.config.interval_days ?? 7)d")
                        }
                        Spacer()
                        Text("Size: \(formatCurrency(fund.config.fund_size_usd ?? 0))")
                    }
                    .font(.caption)
                    .foregroundColor(.textMuted)
                    .padding(8)
                    .background(Color.bgCard)
                    .cornerRadius(8)

                    // Recommendation
                    if let rec {
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

                    // Stats grid
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                        StatBox(label: "Invested", value: formatCurrency(state.startInputUsd))
                        StatBox(label: "Asset Value", value: formatCurrency(value), color: value >= state.startInputUsd ? .mint : .red)
                        StatBox(label: "Unrealized", value: "\(state.gainUsd >= 0 ? "+" : "")\(formatCurrency(state.gainUsd))", color: state.gainUsd >= 0 ? .mint : .red)
                        StatBox(label: "Realized", value: formatCurrency(state.realizedGainsUsd), color: state.realizedGainsUsd > 0 ? .mint : .white)
                        StatBox(label: "Realized APY", value: formatPercent(realizedAPY), color: realizedAPY > 0 ? .mint : .red)
                        StatBox(label: "Liquid P&L", value: formatCurrency(liquidGain), color: liquidGain >= 0 ? .mint : .red)
                        StatBox(label: "Liquid APY", value: formatPercent(liquidAPY), color: liquidAPY > 0 ? .mint : .red)
                        StatBox(label: "Cash", value: formatCurrency(state.cashAvailableUsd))
                    }

                    // Value chart
                    if fund.entries.count >= 3 {
                        ValueChartView(entries: fund.entries)
                    }

                    // Entries
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entries (\(fund.entries.count))")
                            .font(.headline).foregroundColor(.white)

                        ForEach(Array(fund.entries.suffix(30).reversed().enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Text(entry.date).font(.caption).foregroundColor(.textSecondary)
                                Text(entry.action?.rawValue ?? "HOLD").font(.caption).fontWeight(.medium)
                                    .foregroundColor(entry.action == .BUY || entry.action == .DEPOSIT ? .mint : entry.action == .SELL || entry.action == .WITHDRAW ? .red : .textSecondary)
                                Spacer()
                                Text(formatCurrency(entry.value)).font(.caption).foregroundColor(.white)
                                if let amt = entry.amount {
                                    Text(formatCurrency(amt)).font(.caption).foregroundColor(.textSecondary)
                                        .frame(width: 70, alignment: .trailing)
                                }
                            }
                        }

                        if fund.entries.count > 30 {
                            Text("... and \(fund.entries.count - 30) more")
                                .font(.caption).foregroundColor(.textMuted)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(12)
                    .background(Color.bgCard)
                    .cornerRadius(12)
                }
                .padding()
                .padding(.bottom, 80)
            }
            .background(Color.bg.ignoresSafeArea())

            // FAB
            Button { showAddEntry = true } label: {
                Text("+ Take Action")
                    .font(.headline).foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.mint)
                    .cornerRadius(12)
            }
            .padding()
        }
    }

    private func loadFund() async {
        fund = await FundStore.shared.readFundById(fundId)
    }
}

struct StatBox: View {
    let label: String
    let value: String
    var color: Color = .white

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

// MARK: - Swift Charts

struct ValueChartView: View {
    let entries: [FundEntry]

    var body: some View {
        let step = max(1, entries.count / 60)
        let sampled = entries.enumerated().filter { $0.offset % step == 0 || $0.offset == entries.count - 1 }.map(\.element)

        VStack(alignment: .leading, spacing: 8) {
            Text("Value Over Time")
                .font(.headline).foregroundColor(.white)

            Chart(sampled, id: \.date) { entry in
                LineMark(
                    x: .value("Date", entry.date),
                    y: .value("Value", entry.value)
                )
                .foregroundStyle(Color.mint)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Date", entry.date),
                    y: .value("Value", entry.value)
                )
                .foregroundStyle(Color.mint.opacity(0.15))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let str = value.as(String.self) {
                            Text(String(str.suffix(5)))
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatCurrency(v))
                                .font(.caption2).foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }
}
