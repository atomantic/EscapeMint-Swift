import SwiftUI
import Charts

struct DashboardView: View {
    @State private var funds: [FundData] = []
    @State private var showCreateFund = false

    var activeFunds: [FundData] { funds.filter { $0.config.status != .closed } }
    var closedFunds: [FundData] { funds.filter { $0.config.status == .closed } }

    var aggregate: AggregateMetrics {
        computeAggregate(funds)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Aggregate metrics
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            MetricCard(label: "Fund Size", value: formatCurrency(aggregate.totalFundSize), sub: "\(funds.count) funds")
                            MetricCard(label: "Current Value", value: formatCurrency(aggregate.totalValue), sub: "\(activeFunds.count) active")
                            MetricCard(label: "Realized", value: formatCurrency(aggregate.totalRealized), color: aggregate.totalRealized > 0 ? .mint : .red)
                            MetricCard(label: "Realized APY", value: formatPercent(aggregate.realizedAPY), color: aggregate.realizedAPY > 0 ? .mint : .red)
                            MetricCard(label: "Unrealized", value: formatCurrency(aggregate.totalUnrealized), color: aggregate.totalUnrealized >= 0 ? .mint : .red)
                            MetricCard(label: "Liquid Gain", value: formatCurrency(aggregate.totalLiquid), color: aggregate.totalLiquid >= 0 ? .mint : .red)
                            MetricCard(label: "Liquid APY", value: formatPercent(aggregate.liquidAPY), color: aggregate.liquidAPY > 0 ? .mint : .red)
                            MetricCard(label: "Cash", value: formatCurrency(aggregate.cashBalance), sub: "Int: \(formatCurrency(aggregate.totalInterest))")
                        }
                        .padding(.horizontal)
                    }

                    // Fund cards grouped by platform
                    let grouped = Dictionary(grouping: activeFunds, by: { $0.platform })
                    ForEach(grouped.keys.sorted(), id: \.self) { platform in
                        Section {
                            ForEach(grouped[platform]!, id: \.id) { fund in
                                NavigationLink(destination: FundDetailView(fundId: fund.id)) {
                                    FundCardView(fund: fund)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text(platform)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)
                                .textCase(.none)
                        }
                    }

                    if !closedFunds.isEmpty {
                        Section {
                            ForEach(closedFunds, id: \.id) { fund in
                                NavigationLink(destination: FundDetailView(fundId: fund.id)) {
                                    FundCardView(fund: fund)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Closed")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)
                        }
                    }

                    if funds.isEmpty {
                        VStack(spacing: 8) {
                            Text("No funds yet")
                                .font(.title2).fontWeight(.semibold)
                                .foregroundColor(.white)
                            Text("Tap + to create a fund\nor go to Settings to generate test data")
                                .font(.subheadline)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 60)
                    }
                }
                .padding(.bottom, 32)
            }
            .background(Color.bg)
            .navigationTitle("EscapeMint")
            .toolbar {
                Button {
                    showCreateFund = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.mint)
                }
            }
            .sheet(isPresented: $showCreateFund) {
                CreateFundView { loadFunds() }
            }
            .task { loadFunds() }
            .refreshable { loadFunds() }
        }
    }

    private func loadFunds() {
        Task {
            funds = await FundStore.shared.readAllFunds()
                .sorted { getLatestValue($0.entries) > getLatestValue($1.entries) }
        }
    }
}

// MARK: - Aggregate

struct AggregateMetrics {
    var totalFundSize: Double = 0
    var totalValue: Double = 0
    var totalRealized: Double = 0
    var totalUnrealized: Double = 0
    var totalLiquid: Double = 0
    var realizedAPY: Double = 0
    var liquidAPY: Double = 0
    var cashBalance: Double = 0
    var totalInterest: Double = 0
}

func computeAggregate(_ funds: [FundData]) -> AggregateMetrics {
    let today = todayString()
    var m = AggregateMetrics()
    var totalTWFS = 0.0
    var totalDays = 0

    for fund in funds {
        let trades = entriesToTrades(fund.entries)
        let cashflows = entriesToCashFlows(fund.entries)
        let dividends = entriesToDividends(fund.entries)
        let expenses = entriesToExpenses(fund.entries)
        let value = getLatestValue(fund.entries)
        let startDate = getFundStartDate(fund.entries)
        let days = max(1, daysBetween(startDate, today))

        let state = computeFundState(config: fund.config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: expenses, actualValue: value, asOfDate: today)
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: startDate, asOfDate: today)

        if fund.config.status != .closed {
            m.totalFundSize += fund.config.fund_size_usd ?? 0
            m.totalValue += value
            m.totalUnrealized += state.gainUsd
            if isCashFund(fund.config.fund_type) {
                m.cashBalance += value
            }
        }
        m.totalRealized += state.realizedGainsUsd
        m.totalInterest += state.cashInterestUsd
        totalTWFS += twfs
        totalDays += days
    }

    m.totalLiquid = m.totalRealized + m.totalUnrealized
    let avgDays = funds.isEmpty ? 1 : totalDays / funds.count
    m.realizedAPY = computeRealizedAPY(m.totalRealized, totalTWFS, avgDays)
    m.liquidAPY = computeRealizedAPY(m.totalLiquid, totalTWFS, avgDays)

    return m
}

// MARK: - Subviews

struct MetricCard: View {
    let label: String
    let value: String
    var sub: String? = nil
    var color: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.callout).fontWeight(.bold).foregroundColor(color ?? .white)
            if let sub { Text(sub).font(.caption2).foregroundColor(.textMuted) }
        }
        .padding(10)
        .background(Color.bgCard)
        .cornerRadius(10)
        .frame(minWidth: 110)
    }
}

struct FundCardView: View {
    let fund: FundData

    var body: some View {
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
        let isCash = isCashFund(fund.config.fund_type)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(Color.forCategory(fund.config.category))
                    .frame(width: 8, height: 8)
                Text(fund.ticker.uppercased())
                    .font(.headline).foregroundColor(.white)
                Text(features.label)
                    .font(.caption2).foregroundColor(.textMuted)
                if fund.config.status == .closed {
                    Text("Closed").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.bgInput).cornerRadius(4)
                        .foregroundColor(.textMuted)
                }
                Spacer()
                if let rec {
                    Text("\(rec.action.rawValue) \(formatCurrency(rec.amount))")
                        .font(.caption2).fontWeight(.semibold).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(rec.action == .BUY ? Color.mintDark : rec.action == .SELL ? Color.red : Color.bgInput)
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 12) {
                if isCash {
                    VStack(alignment: .leading) {
                        Text("Balance").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(value)).font(.caption).foregroundColor(.white)
                    }
                    VStack(alignment: .leading) {
                        Text("Interest").font(.caption2).foregroundColor(.textMuted)
                        Text("+\(formatCurrency(state.cashInterestUsd))").font(.caption).foregroundColor(.mint)
                    }
                    VStack(alignment: .leading) {
                        Text("APY").font(.caption2).foregroundColor(.textMuted)
                        Text(formatPercent(realizedAPY)).font(.caption).foregroundColor(realizedAPY > 0 ? .mint : .white)
                    }
                } else {
                    VStack(alignment: .leading) {
                        Text("Size").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(fund.config.fund_size_usd ?? 0)).font(.caption).foregroundColor(.white)
                    }
                    VStack(alignment: .leading) {
                        Text("Value").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(value)).font(.caption).foregroundColor(.white)
                    }
                    VStack(alignment: .leading) {
                        Text("Realized").font(.caption2).foregroundColor(.textMuted)
                        Text(formatPercent(realizedAPY)).font(.caption).foregroundColor(realizedAPY > 0 ? .mint : .red)
                    }
                    VStack(alignment: .leading) {
                        Text("Liquid").font(.caption2).foregroundColor(.textMuted)
                        Text(formatPercent(liquidAPY)).font(.caption).foregroundColor(liquidAPY > 0 ? .mint : .red)
                    }
                }
            }

            HStack {
                Text("\(fund.entries.count) entries").font(.caption2).foregroundColor(.textMuted)
                Spacer()
                if let first = fund.entries.first, let last = fund.entries.last {
                    Text("\(first.date) → \(last.date)").font(.caption2).foregroundColor(.textMuted)
                }
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        .padding(.horizontal)
    }
}
