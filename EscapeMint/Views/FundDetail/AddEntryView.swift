import SwiftUI
import os

private let addEntryLogger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "AddEntry")

struct NumericFieldRow: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var hint: String? = nil
    var sign: String? = nil

    private var formulaHint: String? {
        guard isFormula(text) else { return nil }
        let result = parseFormulaValue(text)
        if result == 0 && !text.contains("0") { return nil }
        let formatted = result.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", result)
            : String(format: "%.2f", result)
        return "= \(formatted)"
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.textPrimary)
            Spacer()
            if let sign {
                Text(sign)
                    .foregroundColor(.textMuted)
                    .font(.callout)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.textMuted.opacity(0.5)))
                .formulaKeyboard()
                .multilineTextAlignment(.trailing)
                #if os(macOS)
                .frame(maxWidth: 200)
                .textFieldStyle(.roundedBorder)
                #endif
                .onChange(of: text) { _, newValue in
                    if sign != nil && newValue.contains("-") {
                        text = newValue.replacingOccurrences(of: "-", with: "")
                    }
                }
            if let formulaHint {
                Text(formulaHint)
                    .font(.caption)
                    .foregroundColor(.mint)
                    .frame(minWidth: 60, alignment: .trailing)
            } else if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.textMuted)
                    .frame(minWidth: 50, alignment: .trailing)
            }
        }
    }
}

/// Compute cumulative shares from entries before a given date
func getCumulativeShares(entries: [FundEntry], beforeDate: String) -> Double {
    let sorted = entries.sorted { $0.date < $1.date }
    var total: Double = 0
    for entry in sorted {
        if entry.date >= beforeDate { break }
        if let s = entry.shares {
            total += entry.action == .SELL ? -abs(s) : abs(s)
        }
    }
    return total
}

/// Total shares across all entries
func getTotalShares(entries: [FundEntry]) -> Double {
    entries.reduce(0.0) { acc, entry in
        guard let s = entry.shares else { return acc }
        return acc + (entry.action == .SELL ? -abs(s) : abs(s))
    }
}

/// Format total shares as a display hint
func formatSharesHint(_ total: Double) -> String? {
    guard total > 0 else { return nil }
    if total == total.rounded() {
        return String(format: "%.0f", total)
    }
    return String(format: "%.1f", total)
}

/// Compute fund_size for an entry based on all entries up to and including it.
/// For manage_cash=false: fund_size = net invested (BUYs - SELLs), resets on full liquidation.
/// For manage_cash=true: fund_size = previous fund_size + deposits - withdrawals (carried forward).
func computeFundSizeForEntry(_ newEntry: FundEntry, existingEntries: [FundEntry], config: FundConfig) -> Double {
    let manageCash = config.manage_cash != false
    let isAccumulate = config.accumulate == true

    // Build the full entry list including the new one, sorted by date
    let allEntries = (existingEntries + [newEntry]).sorted { $0.date < $1.date }

    if !manageCash {
        // Non-cash managing: fund_size = cumulative BUYs - SELLs
        var invested = 0.0
        var sumShares = 0.0
        for e in allEntries {
            if e.date > newEntry.date { break }
            if let s = e.shares {
                sumShares += e.action == .SELL ? -abs(s) : abs(s)
            }
            if e.action == .BUY, let amt = e.amount {
                invested += amt
            } else if e.action == .SELL, let amt = e.amount {
                if !isAccumulate {
                    invested -= amt
                }
                // Check full liquidation (use OR — either condition triggers)
                let hasShareTracking = e.shares != nil && (e.shares ?? 0) != 0
                let sharesLiquidated = hasShareTracking && abs(sumShares) < 0.0001
                let valueLiquidated = e.value > 0 && e.value <= amt + 0.01
                let isLiquidation = sharesLiquidated || valueLiquidated
                if isLiquidation {
                    invested = 0
                    sumShares = 0
                }
            }
        }
        return max(0, invested)
    } else {
        // Cash managing: carry forward from previous entry, adjust for deposits/withdrawals
        let entriesBefore = allEntries.filter { $0.date < newEntry.date }
        let prevFundSize = entriesBefore.last?.fund_size ?? 0

        // Check for deposit/withdrawal in notes
        var depositAmount = 0.0
        var withdrawalAmount = 0.0
        if let notes = newEntry.notes {
            if let match = notes.range(of: #"Deposit:\s*\$?([\d.]+)"#, options: .regularExpression) {
                let numStr = notes[match].replacingOccurrences(of: "Deposit:", with: "")
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
                depositAmount = Double(numStr) ?? 0
            }
            if let match = notes.range(of: #"Withdrawal:\s*\$?([\d.]+)"#, options: .regularExpression) {
                let numStr = notes[match].replacingOccurrences(of: "Withdrawal:", with: "")
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
                withdrawalAmount = Double(numStr) ?? 0
            }
        }
        if newEntry.action == .DEPOSIT, let amt = newEntry.amount { depositAmount = amt }
        if newEntry.action == .WITHDRAW, let amt = newEntry.amount { withdrawalAmount = amt }

        let adjustment = depositAmount - withdrawalAmount
        return adjustment != 0 ? prevFundSize + adjustment : prevFundSize
    }
}

/// Auto-sync a trade to the platform's cash fund when the trading fund doesn't manage its own cash.
/// BUY → WITHDRAW from cash, SELL → DEPOSIT to cash.
@MainActor
func autoSyncCashFund(fundId: String, entry: FundEntry, config: FundConfig) async {
    let manageCash = config.manage_cash != false
    guard !manageCash, let amt = entry.amount, amt > 0,
          (entry.action == .BUY || entry.action == .SELL) else {
        addEntryLogger.debug("autoSyncCashFund skipped for \(fundId, privacy: .private): manageCash=\(config.manage_cash != false), amount=\(entry.amount ?? 0), action=\(entry.action?.rawValue ?? "nil")")
        return
    }

    let platform = fundId.components(separatedBy: "-").first ?? ""
    let cashFundId = "\(platform)-cash"
    let store = FundDataStore.shared
    guard let cashFund = store.funds.first(where: { $0.id == cashFundId }) else {
        addEntryLogger.debug("autoSyncCashFund no cash fund found for platform '\(platform, privacy: .private)' (expected \(cashFundId, privacy: .private))")
        return
    }

    let ticker = fundId.replacingOccurrences(of: "\(platform)-", with: "").uppercased()
    let isBuy = entry.action == .BUY
    let prevCash = cashFund.entries.last?.cash ?? cashFund.entries.last?.value ?? 0
    let newCash = isBuy ? prevCash - amt : prevCash + amt
    var cashEntry = FundEntry(
        date: entry.date,
        value: max(0, newCash),
        cash: max(0, newCash),
        action: isBuy ? .WITHDRAW : .DEPOSIT,
        amount: amt
    )
    cashEntry.fund_size = cashFund.entries.last?.fund_size ?? 0
    cashEntry.notes = "Auto: \(entry.action?.rawValue ?? "") \(ticker) $\(String(format: "%.2f", amt))"
    await store.appendEntry(fundId: cashFundId, entry: cashEntry)
}

struct AddEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let fundId: String
    let fundType: FundType
    let fundConfig: FundConfig
    var existingEntries: [FundEntry] = []
    var recommendation: Recommendation? = nil
    let onSaved: () -> Void

    @State private var date = Date()
    @State private var action: FundAction = .BUY
    @State private var value = ""
    @State private var amount = ""
    @State private var shares = ""
    @State private var price = ""
    @State private var deposit = ""
    @State private var withdrawal = ""
    @State private var dividend = ""
    @State private var cashInterest = ""
    @State private var fee = ""
    @State private var marginAvailable = ""
    @State private var marginBorrowed = ""
    @State private var notes = ""
    @State private var fundSizeOverride = ""
    @State private var isSaving = false
    @State private var showOptional: Bool

    init(fundId: String, fundType: FundType, fundConfig: FundConfig, existingEntries: [FundEntry] = [], recommendation: Recommendation? = nil, onSaved: @escaping () -> Void) {
        self.fundId = fundId
        self.fundType = fundType
        self.fundConfig = fundConfig
        self.existingEntries = existingEntries
        self.recommendation = recommendation
        self.onSaved = onSaved
        let key = "addEntry_showOptional_\(fundId)"
        _showOptional = State(initialValue: UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key))
    }

    private var isCash: Bool { isCashFund(fundType) }

    private var features: FundTypeFeatures {
        getFeatures(fundType)
    }

    private var totalSharesHint: String? {
        formatSharesHint(getTotalShares(entries: existingEntries))
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCash {
                    cashForm
                } else {
                    tradingForm
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isCash ? "Cash Balance Entry" : "Add Entry")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 380)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { isCash ? saveCash() : save() }
                        .disabled(isSaving)
                }
            }
            .onAppear {
                if isCash {
                    // Pre-fill cash balance from last entry
                    if let last = existingEntries.last {
                        value = String(format: "%.2f", last.cash ?? last.value)
                    }
                } else if let rec = recommendation {
                    action = rec.action
                    if rec.amount > 0 {
                        amount = String(format: "%.2f", rec.amount)
                    }
                    // Default equity to last entry's value, or 0 for new funds
                    if value.isEmpty {
                        if let last = existingEntries.last {
                            value = String(format: "%.2f", last.value)
                        } else {
                            value = "0.00"
                        }
                    }
                } else {
                    action = .BUY
                    if value.isEmpty {
                        if let last = existingEntries.last {
                            value = String(format: "%.2f", last.value)
                        } else {
                            value = "0.00"
                        }
                    }
                }
            }
            .onChange(of: showOptional) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "addEntry_showOptional_\(fundId)")
            }
        }
    }

    // MARK: - Cash Fund Form

    @ViewBuilder
    private var cashForm: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            NumericFieldRow(label: "Cash Balance ($)", text: $value)
            NumericFieldRow(label: "Amount ($)", placeholder: "+100 or -50", text: $amount)
        } footer: {
            Text("Positive amount = deposit, negative = withdraw")
        }

        Section("Details") {
            NumericFieldRow(label: "Interest Earned ($)", text: $cashInterest)
            NumericFieldRow(label: "Fee ($)", text: $fee, sign: "-")
            if features.supportsMargin {
                NumericFieldRow(label: "Margin Available ($)", text: $marginAvailable)
                NumericFieldRow(label: "Margin Borrowed ($)", text: $marginBorrowed, sign: "-")
            }
            TextField("Notes", text: $notes)
        }
    }

    // MARK: - Trading Fund Form

    @ViewBuilder
    private var tradingForm: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Picker("Action", selection: $action) {
                Text("BUY").tag(FundAction.BUY)
                Text("SELL").tag(FundAction.SELL)
                Text("HOLD").tag(FundAction.HOLD)
            }
        }

        Section {
            NumericFieldRow(label: "Equity ($)", placeholder: "Portfolio value", text: $value)
            NumericFieldRow(label: "Amount ($)", placeholder: action == .HOLD ? "N/A" : "Buy/sell amount", text: $amount)
                .disabled(action == .HOLD)
                .opacity(action == .HOLD ? 0.5 : 1)
        } header: {
            Text("Action")
        }

        Section(isExpanded: $showOptional) {
            if features.supportsShares {
                NumericFieldRow(label: "Shares/Units", text: $shares, hint: totalSharesHint)
                NumericFieldRow(label: "Price ($)", placeholder: "Per unit", text: $price)
                Button("Calc Price/Equity") { calcPriceEquity() }
                    .font(.callout)
                    .foregroundColor(.mint)
            }
            if features.supportsDividends {
                NumericFieldRow(label: "Dividend ($)", text: $dividend)
            }
            if features.supportsMargin {
                NumericFieldRow(label: "Margin Available ($)", text: $marginAvailable)
                NumericFieldRow(label: "Margin Borrowed ($)", text: $marginBorrowed, sign: "-")
            }
            NumericFieldRow(label: "Deposit ($)", text: $deposit)
            NumericFieldRow(label: "Withdrawal ($)", text: $withdrawal, sign: "-")
            TextField("Notes", text: $notes)
        } header: {
            HStack {
                Text("Optional")
                Spacer()
                Image(systemName: showOptional ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundColor(.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture { showOptional.toggle() }
        }
    }

    private func calcPriceEquity() {
        guard let result = calcPriceAndEquity(amount: amount, shares: shares, existingEntries: existingEntries, date: date, dollarDecimals: fundConfig.dollarDec) else { return }
        price = result.price
        if !result.value.isEmpty { value = result.value }
    }

    private func saveCash() {
        guard !isSaving else { return }
        isSaving = true
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let cashBalance = r(parseFormulaValue(value))
        let amt = r(parseFormulaValue(amount))
        // Adjust cash balance by the amount (positive = deposit, negative = withdraw)
        let adjustedCash = r(max(0, cashBalance + amt))
        let entryAction: FundAction? = amt > 0 ? .DEPOSIT : amt < 0 ? .WITHDRAW : nil
        var entry = FundEntry(
            date: isoDateFormatter.string(from: date),
            value: adjustedCash,
            cash: adjustedCash,
            action: entryAction,
            amount: amt != 0 ? abs(amt) : nil
        )
        let ci = r(parseFormulaValue(cashInterest)); if ci != 0 { entry.cash_interest = ci }
        let f = r(parseFormulaValue(fee)); if f != 0 { entry.expense = f }
        let ma = r(parseFormulaValue(marginAvailable)); if ma != 0 { entry.margin_available = ma }
        let mb = r(parseFormulaValue(marginBorrowed)); if mb != 0 { entry.margin_borrowed = mb }
        if !notes.isEmpty { entry.notes = notes }
        let fs = r(parseFormulaValue(fundSizeOverride)); if fs > 0 {
            entry.fund_size = fs
        } else {
            entry.fund_size = computeFundSizeForEntry(entry, existingEntries: existingEntries, config: fundConfig)
        }

        dismiss()
        Task {
            await FundDataStore.shared.appendEntry(fundId: fundId, entry: entry)
            onSaved()
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var entry = FundEntry(
            date: isoDateFormatter.string(from: date),
            value: r(parseFormulaValue(value)),
            action: action
        )
        let amt = r(parseFormulaValue(amount)); if amt != 0 { entry.amount = amt }
        let s = parseFormulaValue(shares); if s != 0 { entry.shares = s }
        let p = parseFormulaValue(price); if p != 0 { entry.price = p }
        let d = r(parseFormulaValue(deposit)); if d != 0 {
            let depNote = "Deposit: $\(String(format: "%.2f", d))"
            notes = notes.isEmpty ? depNote : "\(notes) | \(depNote)"
        }
        let w = r(parseFormulaValue(withdrawal)); if w != 0 {
            let wNote = "Withdrawal: $\(String(format: "%.2f", w))"
            notes = notes.isEmpty ? wNote : "\(notes) | \(wNote)"
        }
        let dv = r(parseFormulaValue(dividend)); if dv != 0 { entry.dividend = dv }
        let ma = r(parseFormulaValue(marginAvailable)); if ma != 0 { entry.margin_available = ma }
        let mb = r(parseFormulaValue(marginBorrowed)); if mb != 0 { entry.margin_borrowed = mb }
        if !notes.isEmpty { entry.notes = notes }

        // Compute fund_size
        entry.fund_size = computeFundSizeForEntry(entry, existingEntries: existingEntries, config: fundConfig)

        dismiss()
        Task {
            await FundDataStore.shared.appendEntry(fundId: fundId, entry: entry)
            await autoSyncCashFund(fundId: fundId, entry: entry, config: fundConfig)
            onSaved()
        }
    }
}
