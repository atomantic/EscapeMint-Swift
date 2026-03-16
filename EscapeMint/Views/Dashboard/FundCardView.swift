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
                        .background(rec.action == .BUY ? Color.mintDark : rec.action == .SELL ? Color.red : Color.bgInput)
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 12) {
                if summary.isCash {
                    VStack(alignment: .leading) {
                        Text("Balance").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(value)).font(.caption).foregroundColor(.textPrimary)
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
                        Text(formatCurrency(fund.config.fund_size_usd ?? 0)).font(.caption).foregroundColor(.textPrimary)
                    }
                    VStack(alignment: .leading) {
                        Text("Value").font(.caption2).foregroundColor(.textMuted)
                        Text(formatCurrency(value)).font(.caption).foregroundColor(.textPrimary)
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
                    Text("\(first.date) \u{2192} \(last.date)").font(.caption2).foregroundColor(.textMuted)
                }
            }
        }
        .padding(12)
        .background(Color.bgCard)
        .cornerRadius(12)
        #if os(iOS)
        .padding(.horizontal)
        #endif
    }
}
