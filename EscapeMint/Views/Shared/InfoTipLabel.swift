import SwiftUI

/// A label with a tappable info icon that shows a popover/alert with help text.
struct InfoTipLabel: View {
    let label: String
    let tip: String
    @State private var showTip = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundColor(.textSecondary)
            Button { showTip = true } label: {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundColor(.textMuted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("More information about \(label)")
            .accessibilityHint("Shows help for \(label)")
            #if os(iOS)
            .popover(isPresented: $showTip) {
                Text(tip)
                    .font(.callout)
                    .foregroundColor(.textPrimary)
                    .padding()
                    .frame(maxWidth: 300)
                    .presentationCompactAdaptation(.popover)
            }
            #else
            .popover(isPresented: $showTip) {
                Text(tip)
                    .font(.callout)
                    .foregroundColor(.textPrimary)
                    .padding()
                    .frame(maxWidth: 300)
            }
            #endif
        }
    }
}

// MARK: - DCA Help Text

enum DCAHelp {
    static let targetApy = "The annual percentage yield you're targeting. The system compares current performance against this to determine buy/sell recommendations."
    static let interval = "How many days between each DCA action. 7 = weekly, 14 = biweekly, 30 = monthly."
    static let minDCA = "Amount to invest when the asset is performing at or above your target APY."
    static let midDCA = "Amount to invest when the asset is underperforming your target."
    static let maxDCA = "Amount to invest when the asset has dropped significantly (below the max threshold)."
    static let maxThreshold = "The loss percentage that triggers the max DCA amount. e.g. -25 means if performance is below -25%, use the max amount."
    static let minProfit = "Minimum dollar profit required before the system recommends selling. Prevents selling for tiny gains."
    static let accumulate = "In accumulate mode, sell recommendations only cover the DCA amount — preserving your core position. When off (harvest mode), the system may recommend selling the full position."
    static let manageCash = "When on, this fund maintains its own cash pile for DCA purchases. When off, cash is tracked at the platform level in a separate cash fund."
    static let category = "Categories group your funds by investment strategy: Liquidity (cash access), Yield (stable income), Store of Value (inflation hedge), Volatility (market swings)."
}
