import SwiftUI

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
                    .font(.headline).foregroundColor(.textPrimary)
                Text(features.label)
                    .font(.caption2).foregroundColor(.textMuted)
                if fund.config.status == .closed {
                    Text("Closed").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.bgInput).cornerRadius(4)
                        .foregroundColor(.textMuted)
                }
                if summary.fundSharesPct > 0 {
                    Text(formatPercent(summary.fundSharesPct))
                        .font(.caption2).foregroundColor(.textMuted)
                }
                Spacer()
                if let rec {
                    let isHold = rec.action == .HOLD
                    Text("\(rec.action.rawValue) \(formatCurrency(rec.amount))")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundColor(isHold ? .textMuted : .white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.backgroundForAction(rec.action))
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 12) {
                if fund.config.status == .closed {
                    metricColumn("Size", formatCurrency(summary.metrics.fundSize))
                    metricColumn("Realized $", formatCurrency(summary.effectiveRealized),
                                 color: summary.effectiveRealized >= 0 ? .mint : .red)
                    metricColumn("Realized %", formatPercent(summary.effectiveRealizedAPY),
                                 color: summary.effectiveRealizedAPY >= 0 ? .mint : .red)
                } else if summary.isCash {
                    metricColumn("Balance", formatCurrency(value))
                    metricColumn("Interest", "+\(formatCurrency(state.cashInterestUsd))", color: .mint)
                    metricColumn("APY", formatPercent(realizedAPY),
                                 color: realizedAPY > 0 ? .mint : .textMuted)
                } else {
                    metricColumn("Size", formatCurrency(summary.metrics.fundSize))
                    metricColumn("Value", formatCurrency(value))
                    metricColumn("Realized", formatPercent(realizedAPY),
                                 color: realizedAPY > 0 ? .mint : .red)
                    metricColumn("Liquid", formatPercent(liquidAPY),
                                 color: liquidAPY > 0 ? .mint : .red)
                }
            }

            HStack {
                Text("\(fund.entries.count) entries").font(.caption2).foregroundColor(.textMuted)
                Spacer()
                if let first = fund.entries.first, let last = fund.entries.last {
                    Text("\(first.date) \u{2192} \(last.date)").font(.caption2).foregroundColor(.textMuted)
                }
            }
        }
        .padding(12)
        .cardStyle()
        #if os(iOS)
        .padding(.horizontal)
        #endif
    }

    private func metricColumn(_ label: String, _ value: String, color: Color = .textPrimary) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption2).foregroundColor(.textMuted)
            Text(value).font(.caption).foregroundColor(color)
        }
    }
}
