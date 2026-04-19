import Foundation
import SwiftUI

/// Compute a live DCA recommendation using a user-supplied current equity, so the guided
/// Add-Entry wizard can show what the engine suggests BEFORE the user records the action.
///
/// Mirrors the state assembly in `FundSummary.init` (FundTypes.swift) but replaces the
/// last-entry-derived `actualValueUsd` with the value the user just reported. For
/// `manage_cash=false` funds, `cashAvailableUsd` is sourced from the platform cash fund
/// exactly like `FundSummary` does.
@MainActor
func recommendationForLiveEquity(fund: FundData, currentEquity: Double) -> Recommendation? {
    let today = todayString()
    let trades = entriesToTrades(fund.entries)
    let cashflows = entriesToCashFlows(fund.entries)
    let divs = entriesToDividends(fund.entries)
    let exps = entriesToExpenses(fund.entries)
    var state = computeFundState(
        config: fund.config,
        trades: trades,
        cashflows: cashflows,
        dividends: divs,
        expenses: exps,
        actualValue: currentEquity,
        asOfDate: today
    )

    // For funds that don't manage their own cash, cash lives in the platform cash fund.
    if fund.config.manage_cash == false {
        let cashFundId = resolveCashFundId(config: fund.config, platform: fund.platform)
        if let cashFund = FundDataStore.shared.funds.first(where: { $0.id == cashFundId }),
           let latest = cashFund.entries.max(by: { $0.date < $1.date }) {
            state.cashAvailableUsd = latest.cash ?? latest.value
        } else {
            state.cashAvailableUsd = 0
        }
    }

    // Margin-aware: if margin is enabled, treat available margin as borrowable cash.
    if fund.config.margin_enabled == true,
       let latestEntry = fund.entries.last,
       let marginAvail = latestEntry.margin_available, marginAvail > 0 {
        state.cashAvailableUsd += marginAvail
    }

    return computeRecommendation(config: fund.config, state: state)
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
    if v == v.rounded(.down) { return String(format: "%.0f", v) }
    let s = String(format: "%.8f", v)
    var end = s.endIndex
    while end > s.startIndex && s[s.index(before: end)] == "0" { end = s.index(before: end) }
    if end > s.startIndex && s[s.index(before: end)] == "." { end = s.index(before: end) }
    return String(s[s.startIndex..<end])
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
