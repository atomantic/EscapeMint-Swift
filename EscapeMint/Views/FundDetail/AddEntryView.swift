import SwiftUI
import os

private let addEntryLogger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "AddEntry")

struct NumericFieldRow: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var hint: String? = nil
    var sign: String? = nil
    var autoFocus: Bool = false

    @FocusState private var isFocused: Bool
    @State private var hasAutoFocused = false

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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            if let sign {
                Text(sign)
                    .foregroundColor(.textMuted)
                    .font(.callout)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.textMuted.opacity(0.5)))
                .formulaKeyboard()
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
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
        .onAppear {
            guard autoFocus, !hasAutoFocused else { return }
            hasAutoFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isFocused = true
            }
        }
        #if os(iOS)
        .onChange(of: isFocused) { _, focused in
            if focused {
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
        #endif
    }
}

/// Build the auto-sync cash-fund entry for a trade when the trading fund doesn't
/// manage its own cash. Thin @MainActor wrapper that resolves the platform's cash
/// fund from the store and delegates to the pure `buildCashSyncEntry` engine helper,
/// logging any skip reason. Returns the pending write so the caller can batch it with
/// the trade entry into a single `appendEntries` call (one recompute instead of two).
@MainActor
func buildCashSyncWrite(fundId: String, entry: FundEntry, config: FundConfig) -> (fundId: String, entry: FundEntry)? {
    let platform = fundId.components(separatedBy: "-").first ?? ""
    let cashFundId = "\(platform)-cash"
    let cashFund = FundDataStore.shared.funds.first(where: { $0.id == cashFundId })

    switch buildCashSyncEntry(fundId: fundId, entry: entry, config: config, cashFund: cashFund) {
    case .success(let write):
        return write
    case .failure(let reason):
        switch reason {
        case .managesOwnCash, .notATrade:
            addEntryLogger.debug("cash sync skipped for \(fundId, privacy: .private): manageCash=\(config.manage_cash != false), amount=\(entry.amount ?? 0, privacy: .private), action=\(entry.action?.rawValue ?? "nil")")
        case .noCashFund(let expectedId):
            addEntryLogger.debug("cash sync no cash fund found for platform '\(platform, privacy: .private)' (expected \(expectedId, privacy: .private))")
        }
        return nil
    }
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
        let key = AppStorageKeys.addEntryShowOptional(fundId: fundId)
        _showOptional = State(initialValue: UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key))
    }

    private var isCash: Bool { isCashFund(fundType) }

    private var features: FundTypeFeatures {
        getFeatures(fundType)
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
            // Trading funds have an Optional section that overflows the default
            // window height when expanded, so give them a taller minimum.
            .frame(minWidth: 420, minHeight: isCash ? 380 : 520)
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
                } else {
                    if let rec = recommendation {
                        action = rec.action
                        if rec.amount > 0 {
                            amount = String(format: "%.2f", rec.amount)
                        }
                    } else {
                        action = .BUY
                    }
                    // A full exit leaves no equity for the next position; otherwise
                    // carry forward the last recorded pre-action equity.
                    if value.isEmpty {
                        value = String(format: "%.2f", prefilledEquityValue(for: existingEntries))
                    }
                }
            }
            .onChange(of: showOptional) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: AppStorageKeys.addEntryShowOptional(fundId: fundId))
            }
        }
    }

    // MARK: - Cash Fund Form

    @ViewBuilder
    private var cashForm: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            NumericFieldRow(label: "Cash Balance ($)", text: $value, autoFocus: true)
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
            NumericFieldRow(label: "Amount ($)", placeholder: action == .HOLD ? "N/A" : "Buy/sell amount", text: $amount, autoFocus: true)
                .disabled(action == .HOLD)
                .opacity(action == .HOLD ? 0.5 : 1)
        } header: {
            Text("Action")
        }

        Section(isExpanded: $showOptional) {
            if features.supportsShares {
                NumericFieldRow(label: "Shares/Units", text: $shares)
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

        let cashWrite = buildCashSyncWrite(fundId: fundId, entry: entry, config: fundConfig)
        var writes: [(fundId: String, entry: FundEntry)] = [(fundId, entry)]
        if let cashWrite { writes.append(cashWrite) }
        dismiss()
        Task {
            await FundDataStore.shared.appendEntries(writes: writes)
            onSaved()
        }
    }
}
