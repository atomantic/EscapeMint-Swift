import Foundation
import SwiftUI

/// Compute a live DCA recommendation using a user-supplied current equity, so the guided
/// Add-Entry wizard can show what the engine suggests BEFORE the user records the action.
///
/// Thin @MainActor wrapper that resolves cross-fund cash from `FundDataStore.shared` for
/// `manage_cash=false` funds (exactly like `FundSummary` does) and delegates the actual
/// computation to the pure `recommendationForLiveEquity` engine helper.
@MainActor
func recommendationForLiveEquity(fund: FundData, currentEquity: Double) -> Recommendation? {
    var externalCash: Double?
    if fund.config.manage_cash == false {
        let cashFundId = resolveCashFundId(config: fund.config, platform: fund.platform)
        if let cashFund = FundDataStore.shared.funds.first(where: { $0.id == cashFundId }),
           let latest = cashFund.entries.latestByDate {
            externalCash = latest.cash ?? latest.value
        } else {
            externalCash = 0
        }
    }
    return recommendationForLiveEquity(
        fund: fund,
        currentEquity: currentEquity,
        externalCashAvailable: externalCash
    )
}

/// Calculate price from amount/shares and derive equity from prior shares.
/// Returns (price, equity) or nil if inputs are invalid.
func calcPriceAndEquity(amount: String, shares: String, existingEntries: [FundEntry], date: Date, dollarDecimals: Int = 2) -> (price: String, value: String)? {
    let amountVal = parseFormulaValue(amount)
    let sharesVal = parseFormulaValue(shares)
    guard amountVal > 0, sharesVal > 0 else { return nil }

    let selectedDate = isoDateFormatter.string(from: date)
    let calculatedPrice = amountVal / abs(sharesVal)
    let fmt = "%.\(dollarDecimals)f"
    let priceStr = String(format: fmt, calculatedPrice)

    let prior = getCumulativeShares(entries: existingEntries, beforeDate: selectedDate)
    if prior > 0 {
        let equity = prior * calculatedPrice
        return (priceStr, String(format: fmt, equity))
    }
    return (priceStr, "")
}

// MARK: - Number Formatting for Text Fields

/// Format a currency Double for display in text fields — clean, no precision artifacts.
/// Returns "" for 0 (treats zero as empty).
func cleanNum(_ val: Double) -> String {
    val == 0 ? "" : (val == val.rounded(.down) ? String(format: "%.0f", val) : String(format: "%.2f", val))
}
func cleanNum(_ val: Double?) -> String { val.map { cleanNum($0) } ?? "" }

/// Format a quantity (shares/contracts) — up to 8 decimals, trailing zeros stripped.
func cleanShares(_ val: Double?) -> String {
    guard let v = val, v != 0 else { return "" }
    return formatTrimmedDecimal(v)
}

// MARK: - DCA Form Helpers

/// A labeled text field with an info tip tooltip.
@MainActor @ViewBuilder
func dcaTipField(_ label: String, tip: String, text: Binding<String>, placeholder: String = "0") -> some View {
    HStack {
        InfoTipLabel(label: label, tip: tip)
        Spacer()
        TextField("", text: text, prompt: Text(placeholder))
            .multilineTextAlignment(.trailing)
            .frame(width: 100)
            .numericKeyboard()
    }
}

/// A labeled toggle with an info tip tooltip.
@MainActor @ViewBuilder
func dcaTipToggle(_ label: String, tip: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
        InfoTipLabel(label: label, tip: tip)
    }
}
