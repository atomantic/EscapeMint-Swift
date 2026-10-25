import SwiftUI

/// A label with a tappable info icon that shows a popover/alert with help text.
/// Parent rows must reserve at least 44 points of height for the help button.
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    static let fallback = "For a daily-reset 3x fund only. When this is on, a new buy goes to the 1x ticker once the 3x fund is down past the threshold or the underlying index is below its moving average. Buys return to the 3x fund when the index closes back above that average. Shares you already hold are not sold. This never borrows — do not turn on margin for these funds. A one-day drop of about 33% in the index can wipe a 3x fund out."
    static let fallbackTicker = "Where new buys go while the fallback is active. TQQQ uses QQQ, SOXL uses SOXX, SPXL uses SPY."
    static let fallbackDrawdown = "How far the 3x fund must fall before new buys leave it. 60 means down 60% from the peak of the current uptrend, or 60% below what you paid."
    static let fallbackMA = "Length of the underlying moving average, in days. 200 is the default. Bundled sample prices are weekly, so 200 days is read as a 40-week average."
}
