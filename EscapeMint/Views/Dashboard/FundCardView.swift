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
                        .tagBadge(background: .bgInput)
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
                        .actionBadge(background: Color.backgroundForAction(rec.action))
                }
            }

            HStack(spacing: 12) {
                if fund.config.status == .closed {
                    StatBox(label: "Size", value: formatCurrency(summary.metrics.fundSize), showCard: false)
                    StatBox(label: "Realized $", value: formatCurrency(summary.effectiveRealized),
                            color: summary.effectiveRealized >= 0 ? .mint : .red, showCard: false)
                    StatBox(label: "Realized %", value: formatPercent(summary.effectiveRealizedAPY),
                            color: summary.effectiveRealizedAPY >= 0 ? .mint : .red, showCard: false)
                } else if summary.isCash {
                    StatBox(label: "Balance", value: formatCurrency(value), showCard: false)
                    StatBox(label: "Interest", value: "+\(formatCurrency(state.cashInterestUsd))",
                            color: .mint, showCard: false)
                    StatBox(label: "APY", value: formatPercent(realizedAPY),
                            color: realizedAPY > 0 ? .mint : .textMuted, showCard: false)
                } else {
                    StatBox(label: "Size", value: formatCurrency(summary.metrics.fundSize), showCard: false)
                    StatBox(label: "Value", value: formatCurrency(value), showCard: false)
                    StatBox(label: "Realized", value: formatPercent(realizedAPY),
                            color: realizedAPY > 0 ? .mint : .red, showCard: false)
                    StatBox(label: "Liquid", value: formatPercent(liquidAPY),
                            color: liquidAPY > 0 ? .mint : .red, showCard: false)
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
    }
}

#if DEBUG
#Preview("FundCardView — Active") {
    FundCardView(summary: PreviewData.stockSummary)
        .padding()
        .background(Color.bg)
        .frame(maxWidth: 360)
}

#Preview("FundCardView — Cash") {
    FundCardView(summary: PreviewData.cashSummary)
        .padding()
        .background(Color.bg)
        .frame(maxWidth: 360)
}

#Preview("FundCardView — Closed (Dark)") {
    FundCardView(summary: PreviewData.closedSummary)
        .padding()
        .background(Color.bg)
        .frame(maxWidth: 360)
        .preferredColorScheme(.dark)
}

#Preview("FundCardView — XXL Type") {
    FundCardView(summary: PreviewData.stockSummary)
        .padding()
        .background(Color.bg)
        .frame(maxWidth: 360)
        .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
