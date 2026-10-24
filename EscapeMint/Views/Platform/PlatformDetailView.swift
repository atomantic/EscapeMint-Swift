import SwiftUI
import Charts

struct PlatformDetailView: View {
    let platform: String
    private var store: FundDataStore { .shared }
    @State private var showCreateFund = false

    var platformSummaries: [FundSummary] {
        store.summaries.filter { $0.fund.platform == platform }
            .sorted { $0.currentValue > $1.currentValue }
    }
    var activeSummaries: [FundSummary] { platformSummaries.filter { $0.fund.config.status != .closed } }
    var closedSummaries: [FundSummary] { platformSummaries.filter { $0.fund.config.status == .closed } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                #if os(macOS)
                header
                #endif
                if !platformSummaries.isEmpty {
                    metricsPanel
                    breakdownPanel
                    #if os(macOS)
                    fundsTable
                    #else
                    iosFundsList
                    #endif
                }
            }
            .padding()
        }
        .background(Color.bg.ignoresSafeArea())
        .navigationTitle(platform.capitalized)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showCreateFund = true } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.mint)
            }
        }
        #endif
        .sheet(isPresented: $showCreateFund) {
            CreateFundView(initialPlatform: platform) {}
        }
    }

    // MARK: - Header (macOS)

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
            Button { showCreateFund = true } label: {
                Label("Add Fund", systemImage: "plus.circle.fill")
                    .font(.callout).fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
        }
    }

    // MARK: - P&L Summary

    @ViewBuilder
    private var metricsPanel: some View {
        // Match web app: fundSize/value/invested only from active funds; realized/unrealized from all
        let totalFundSize = activeSummaries.reduce(0.0) { $0 + $1.metrics.fundSize }
        let totalValue = activeSummaries.reduce(0.0) { $0 + $1.currentValue }
        let totalInvested = activeSummaries.reduce(0.0) { $0 + $1.metrics.startInput }
        let totalUnrealized = platformSummaries.reduce(0.0) { $0 + $1.unrealizedGains }
        let totalRealized = platformSummaries.reduce(0.0) { $0 + $1.effectiveRealized }
        let liquidPL = totalUnrealized + totalRealized
        let liquidPct = totalInvested > 0 ? liquidPL / totalInvested : 0

        let cols = platformAdaptiveColumns()
        VStack(alignment: .leading, spacing: 8) {
            Text("P&L Summary")
                .font(.headline).foregroundColor(.textPrimary)

            LazyVGrid(columns: cols, spacing: 10) {
                StatBox(label: "Total Fund Size", value: formatCurrency(totalFundSize))
                StatBox(label: "Current Value", value: formatCurrency(totalValue), color: .mint)
                StatBox(label: "Total Invested", value: formatCurrency(totalInvested))
                StatBox(label: "Unrealized", value: formatCurrency(totalUnrealized), color: Color.gain(totalUnrealized))
                StatBox(label: "Realized", value: formatCurrency(totalRealized), color: Color.gain(totalRealized, includingZero: false))
                StatBox(label: "Liquid P&L", value: "\(formatCurrency(liquidPL)) (\(formatPercent(liquidPct)))", color: Color.gain(liquidPL))
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
    }

    // MARK: - Breakdown

    @ViewBuilder
    private var breakdownPanel: some View {
        // Cash only from active funds; dividends/expenses/interest from all.
        // In-fund cash (see FundMetrics.cash) so shared platform cash is counted once.
        let totalCash = activeSummaries.reduce(0.0) { $0 + $1.metrics.cash }
        let totalDividends = platformSummaries.reduce(0.0) { $0 + $1.metrics.totalDividends }
        let totalExpenses = platformSummaries.reduce(0.0) { $0 + $1.metrics.totalExpenses }
        let totalInterest = platformSummaries.reduce(0.0) { $0 + $1.metrics.totalCashInterest }

        let cols = platformAdaptiveColumns()
        LazyVGrid(columns: cols, spacing: 10) {
            StatBox(label: "Cash", value: formatCurrency(totalCash))
            StatBox(label: "Dividends", value: formatCurrency(totalDividends), color: totalDividends > 0 ? .mint : .textMuted)
            StatBox(label: "Expenses", value: formatCurrency(totalExpenses), color: totalExpenses > 0 ? .red : .textMuted)
            StatBox(label: "Interest", value: formatCurrency(totalInterest), color: totalInterest > 0 ? .mint : .textMuted)
            StatBox(label: "Funds", value: "\(activeSummaries.count) / \(closedSummaries.count)")
        }
    }

    // MARK: - macOS Funds Table

    @ViewBuilder
    private var fundsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Funds")
                .font(.headline).foregroundColor(.textPrimary)

            ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
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
                            Text(formatCurrency(s.metrics.fundSize))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.currentValue))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.metrics.startInput))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.unrealizedGains))
                                .foregroundColor(Color.gain(s.unrealizedGains))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatCurrency(s.effectiveRealized))
                                .foregroundColor(Color.gain(s.effectiveRealized, includingZero: false))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatPercent(s.effectiveRealizedAPY))
                                .foregroundColor(Color.gain(s.effectiveRealizedAPY, includingZero: false))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(formatPercent(s.effectiveLiquidAPY))
                                .foregroundColor(Color.gain(s.effectiveLiquidAPY, includingZero: false))
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
                    .onTapGesture {
                        NotificationCenter.default.postSelectFund(id: s.fund.id)
                    }
                    .onHover { hovering in
                        #if os(macOS)
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        #endif
                    }

                    Divider().background(Color.bgInput)
                }
            }
            .frame(minWidth: 960, alignment: .leading)
            }
            .cornerRadius(8)
        }
    }

    // MARK: - iOS Funds List (card-based)

    @ViewBuilder
    private var iosFundsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Funds")
                .font(.headline).foregroundColor(.textPrimary)

            ForEach(activeSummaries + closedSummaries, id: \.fund.id) { s in
                NavigationLink(destination: FundDetailView(fundId: s.fund.id)) {
                    VStack(spacing: 6) {
                        HStack {
                            Circle().fill(Color.forCategory(s.fund.config.category)).frame(width: 8, height: 8)
                            Text(s.fund.ticker.uppercased())
                                .font(.callout).fontWeight(.semibold).foregroundColor(.textPrimary)
                            Text(s.features.label)
                                .font(.caption2).foregroundColor(.textMuted)
                            if s.fund.config.status == .closed {
                                Text("Closed").font(.caption2)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.bgInput).cornerRadius(3)
                                    .foregroundColor(.textMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(.textMuted)
                        }

                        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 4) {
                            fundMiniStat("Value", formatCurrency(s.currentValue))
                            fundMiniStat("Realized", formatCurrency(s.effectiveRealized), color: Color.gain(s.effectiveRealized, includingZero: false))
                            fundMiniStat("L.APY", formatPercent(s.effectiveLiquidAPY), color: Color.gain(s.effectiveLiquidAPY, includingZero: false))
                        }
                    }
                    .padding(12)
                    .background(Color.bgCard)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func fundMiniStat(_ label: String, _ value: String, color: Color = .textPrimary) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.caption).fontWeight(.medium).foregroundColor(color)
        }
    }

    private func platformAdaptiveColumns() -> [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 140), spacing: 10)]
        #else
        [GridItem(.adaptive(minimum: 130), spacing: 10)]
        #endif
    }

}
