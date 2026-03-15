import SwiftUI
import Charts

struct PlatformDetailView: View {
    let platform: String
    @State private var funds: [FundData] = []
    @State private var summaries: [FundSummary] = []

    var activeSummaries: [FundSummary] { summaries.filter { $0.fund.config.status != .closed } }
    var closedSummaries: [FundSummary] { summaries.filter { $0.fund.config.status == .closed } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if !summaries.isEmpty {
                    metricsPanel
                    breakdownPanel
                    fundsTable
                }
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        .navigationTitle(platform.capitalized)
        .task { await loadFunds() }
        .onReceive(NotificationCenter.default.publisher(for: .fundsDidChange)) { _ in
            Task { await loadFunds() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Dashboard").font(.caption).foregroundColor(.mint)
                    Text("/").font(.caption).foregroundColor(.textMuted)
                    Text(platform.capitalized).font(.caption).foregroundColor(.textPrimary).fontWeight(.medium)
                }
                Text(platform.capitalized)
                    .font(.largeTitle).fontWeight(.bold).foregroundColor(.textPrimary)
                Text("\(activeSummaries.count) active \u{2022} \(closedSummaries.count) closed")
                    .font(.subheadline).foregroundColor(.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - P&L Summary

    @ViewBuilder
    private var metricsPanel: some View {
        let totalFundSize = summaries.reduce(0.0) { $0 + ($1.fund.config.fund_size_usd ?? 0) }
        let totalValue = activeSummaries.reduce(0.0) { $0 + $1.currentValue }
        let totalInvested = activeSummaries.reduce(0.0) { $0 + $1.state.startInputUsd }
        let totalUnrealized = activeSummaries.reduce(0.0) { $0 + $1.unrealizedGains }
        let totalRealized = summaries.reduce(0.0) { $0 + $1.state.realizedGainsUsd }
        let liquidPL = totalUnrealized + totalRealized
        let liquidPct = totalInvested > 0 ? liquidPL / totalInvested : 0

        VStack(alignment: .leading, spacing: 8) {
            Text("P&L Summary")
                .font(.headline).foregroundColor(.textPrimary)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 10) {
                StatBox(label: "Total Fund Size", value: formatCurrency(totalFundSize))
                StatBox(label: "Current Value", value: formatCurrency(totalValue), color: .mint)
                StatBox(label: "Total Invested", value: formatCurrency(totalInvested))
                StatBox(label: "Unrealized", value: formatCurrency(totalUnrealized), color: totalUnrealized >= 0 ? .mint : .red)
                StatBox(label: "Realized", value: formatCurrency(totalRealized), color: totalRealized > 0 ? .mint : .red)
                StatBox(label: "Liquid P&L", value: "\(formatCurrency(liquidPL)) (\(formatPercent(liquidPct)))", color: liquidPL >= 0 ? .mint : .red)
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    // MARK: - Breakdown

    @ViewBuilder
    private var breakdownPanel: some View {
        let totalCash = activeSummaries.reduce(0.0) { $0 + $1.state.cashAvailableUsd }
        let totalDividends = summaries.reduce(0.0) { $0 + entriesToDividends($1.fund.entries).reduce(0.0) { $0 + $1.amountUsd } }
        let totalExpenses = summaries.reduce(0.0) { $0 + entriesToExpenses($1.fund.entries).reduce(0.0) { $0 + $1.amountUsd } }
        let totalInterest = summaries.reduce(0.0) { $0 + $1.state.cashInterestUsd }

        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 5), spacing: 10) {
            miniStat("Cash", formatCurrency(totalCash))
            miniStat("Dividends", formatCurrency(totalDividends), color: totalDividends > 0 ? .mint : .textMuted)
            miniStat("Expenses", formatCurrency(totalExpenses), color: totalExpenses > 0 ? .red : .textMuted)
            miniStat("Interest", formatCurrency(totalInterest), color: totalInterest > 0 ? .mint : .textMuted)
            miniStat("Funds", "\(activeSummaries.count) / \(closedSummaries.count)")
        }
    }

    @ViewBuilder
    private func miniStat(_ label: String, _ value: String, color: Color = .textPrimary) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.caption).fontWeight(.medium).foregroundColor(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.bgCard)
        .cornerRadius(8)
    }

    // MARK: - Funds Table

    @ViewBuilder
    private var fundsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Funds")
                .font(.headline).foregroundColor(.textPrimary)

            VStack(spacing: 0) {
                // Header
                Grid(horizontalSpacing: 8) {
                    GridRow {
                        Text("Fund").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Type").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Size").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Value").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Invested").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Unrealized").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Realized").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("R.APY").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("L.APY").frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Entries").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(.caption2).fontWeight(.semibold)
                .foregroundColor(.textMuted)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.bgInput.opacity(0.5))

                ForEach(activeSummaries + closedSummaries, id: \.fund.id) { s in
                    Grid(horizontalSpacing: 8) {
                        GridRow {
                            HStack(spacing: 4) {
                                Circle().fill(Color.forCategory(s.fund.config.category)).frame(width: 6, height: 6)
                                Text(s.fund.ticker.uppercased()).fontWeight(.medium)
                                if s.fund.config.status == .closed {
                                    Text("Closed").font(.caption2).foregroundColor(.textMuted)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.bgInput).cornerRadius(3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(s.features.label).foregroundColor(.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatCurrency(s.fund.config.fund_size_usd ?? 0))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.currentValue))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.state.startInputUsd))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.unrealizedGains))
                                .foregroundColor(s.unrealizedGains >= 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.state.realizedGainsUsd))
                                .foregroundColor(s.state.realizedGainsUsd > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatPercent(s.realizedAPY))
                                .foregroundColor(s.realizedAPY > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatPercent(s.liquidAPY))
                                .foregroundColor(s.liquidAPY > 0 ? .mint : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text("\(s.fund.entries.count)").foregroundColor(.textMuted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.bgCard)
                    .contentShape(Rectangle())

                    Divider().background(Color.bgInput)
                }
            }
            .cornerRadius(8)
        }
    }

    private func loadFunds() async {
        let allFunds = await FundStore.shared.readAllFunds()
        funds = allFunds.filter { $0.platform == platform }
        summaries = funds.map { FundSummary($0) }
            .sorted { $0.currentValue > $1.currentValue }
    }
}
