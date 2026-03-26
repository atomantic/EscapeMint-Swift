import Foundation
import SwiftUI

/// Calculate price from amount/shares and derive equity from prior shares.
/// Returns (price, equity) or nil if inputs are invalid.
func calcPriceAndEquity(amount: String, shares: String, existingEntries: [FundEntry], date: Date) -> (price: String, value: String)? {
    let amountVal = parseFormulaValue(amount)
    let sharesVal = parseFormulaValue(shares)
    guard amountVal > 0, sharesVal > 0 else { return nil }

    let selectedDate = isoDateFormatter.string(from: date)
    let calculatedPrice = amountVal / abs(sharesVal)
    let priceStr = String(format: "%.8f", calculatedPrice)

    let prior = getCumulativeShares(entries: existingEntries, beforeDate: selectedDate)
    if prior > 0 {
        let equity = prior * calculatedPrice
        return (priceStr, String(format: "%.2f", equity))
    }
    return (priceStr, "")
}

// MARK: - DCA Form Helpers

/// A labeled text field with an info tip tooltip.
@MainActor @ViewBuilder
func dcaTipField(_ label: String, tip: String, text: Binding<String>, prompt: String = "0") -> some View {
    HStack {
        InfoTipLabel(label: label, tip: tip)
        Spacer()
        TextField(prompt, text: text)
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
