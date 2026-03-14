import SwiftUI
import Charts

struct DashboardView: View {
    @State private var funds: [FundData] = []
    @State private var summaries: [FundSummary] = []
    @State private var showCreateFund = false

    var activeSummaries: [FundSummary] { summaries.filter { $0.fund.config.status != .closed } }
    var closedSummaries: [FundSummary] { summaries.filter { $0.fund.config.status == .closed } }

    var aggregate: AggregateMetrics {
        computeAggregate(summaries)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Aggregate metrics
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            MetricCard(label: "Fund Size", value: formatCurrency(aggregate.totalFundSize), sub: "\(funds.count) funds")
                            MetricCard(label: "Current Value", value: formatCurrency(aggregate.totalValue), sub: "\(activeSummaries.count) active")
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
                    let grouped = Dictionary(grouping: activeSummaries, by: { $0.fund.platform })
                    ForEach(grouped.keys.sorted(), id: \.self) { platform in
                        Section {
                            ForEach(grouped[platform]!, id: \.fund.id) { summary in
                                NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                    FundCardView(summary: summary)
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

                    if !closedSummaries.isEmpty {
                        Section {
                            ForEach(closedSummaries, id: \.fund.id) { summary in
                                NavigationLink(destination: FundDetailView(fundId: summary.fund.id)) {
                                    FundCardView(summary: summary)
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
            summaries = funds.map { FundSummary($0) }
                .sorted { $0.currentValue > $1.currentValue }
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

func computeAggregate(_ summaries: [FundSummary]) -> AggregateMetrics {
    var m = AggregateMetrics()
    var totalTWFS = 0.0
    var totalDays = 0

    for s in summaries {
        let isActive = s.fund.config.status != .closed
        if isActive {
            m.totalFundSize += s.fund.config.fund_size_usd ?? 0
            m.totalValue += s.currentValue
            m.totalUnrealized += s.state.gainUsd
            if s.isCash { m.cashBalance += s.currentValue }
        }
        m.totalRealized += s.state.realizedGainsUsd
        m.totalInterest += s.state.cashInterestUsd
        totalTWFS += s.twfs
        totalDays += s.daysActive
    }

    m.totalLiquid = m.totalRealized + m.totalUnrealized
    let avgDays = summaries.isEmpty ? 1 : totalDays / summaries.count
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
    let summary: FundSummary

    var body: some View {
        let fund = summary.fund
        let value = summary.currentValue
        let state = summary.state
        let rec = summary.recommendation
        let features = summary.features
        let realizedAPY = summary.realizedAPY
        let liquidAPY = summary.liquidAPY

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
                if summary.isCash {
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
