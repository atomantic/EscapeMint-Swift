import Foundation

/// Pure presentation logic for the App Intents / Siri Shortcuts surfaces.
///
/// The intents themselves are thin wrappers that read the shared `WidgetSnapshot`
/// from the App Group container and hand it here for phrasing. Keeping the wording
/// in pure functions lets us unit-test the spoken/displayed strings without the
/// AppIntents framework or a live store, and keeps the intent files trivial.
enum PortfolioVoiceSummary {
    /// Spoken/written answer for "What's my portfolio value?".
    static func portfolioValue(_ snapshot: WidgetSnapshot?) -> String {
        guard let snapshot, hasData(snapshot) else { return noDataMessage }
        let value = formatWidgetCurrency(snapshot.totalValue)
        let direction = snapshot.totalGainUsd >= 0 ? "up" : "down"
        let gain = formatWidgetCurrency(abs(snapshot.totalGainUsd))
        let pct = String(format: "%.1f%%", abs(snapshot.totalGainPct))
        return "Your portfolio is worth \(value), \(direction) \(gain) (\(pct)) overall."
    }

    /// Spoken/written answer for "Show my top performer". Picks the fund with the
    /// highest gain percentage among the snapshot's tracked funds.
    static func topPerformer(_ snapshot: WidgetSnapshot?) -> String {
        guard let top = topPerformingFund(snapshot) else { return noDataMessage }
        let value = formatWidgetCurrency(top.value)
        let pct = String(format: "%+.1f%%", top.gainPct)
        return "Your top performer is \(top.ticker) on \(top.platform), \(pct) at \(value)."
    }

    /// The fund used by `topPerformer`, exposed so the intent can also surface
    /// structured fields if it wants. Highest gain percentage wins; ties break
    /// toward the higher-value fund (snapshot is pre-sorted by value).
    static func topPerformingFund(_ snapshot: WidgetSnapshot?) -> WidgetFundSnapshot? {
        snapshot?.topFunds.max { lhs, rhs in
            if lhs.gainPct == rhs.gainPct { return lhs.value < rhs.value }
            return lhs.gainPct < rhs.gainPct
        }
    }

    /// Spoken/written answer for the morning portfolio summary: value, overall
    /// gain, and how many funds are due for a DCA action today.
    static func morningSummary(_ snapshot: WidgetSnapshot?) -> String {
        guard let snapshot, hasData(snapshot) else { return noDataMessage }
        let value = formatWidgetCurrency(snapshot.totalValue)
        let direction = snapshot.totalGainPct >= 0 ? "up" : "down"
        let pct = String(format: "%.1f%%", abs(snapshot.totalGainPct))
        let fundsWord = snapshot.activeFunds == 1 ? "fund" : "funds"

        var summary = "Good morning. Your portfolio is worth \(value), \(direction) \(pct), across \(snapshot.activeFunds) \(fundsWord)."

        if snapshot.actionableCount > 0 {
            let actionWord = snapshot.actionableCount == 1 ? "action is" : "actions are"
            summary += " \(snapshot.actionableCount) \(actionWord) due today."
            if let top = topPerformingFund(snapshot), top.isDueForAction,
               let action = top.recommendedAction {
                let amount = top.recommendedAmount.map { ", around \(formatWidgetCurrency($0))" } ?? ""
                summary += " For example, \(action) \(top.ticker)\(amount)."
            }
        } else {
            summary += " No DCA actions are due today."
        }
        return summary
    }

    /// A snapshot is meaningful once the user has any funds or a non-zero value.
    private static func hasData(_ snapshot: WidgetSnapshot) -> Bool {
        snapshot.activeFunds > 0 || snapshot.totalValue != 0
    }

    static let noDataMessage = "Open EscapeMint to load your portfolio first, then ask again."
}
