import SwiftUI

struct EditEntryView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: FundDataStore { .shared }
    let entry: FundEntry
    let entryIndex: Int
    let fundId: String
    let fundType: FundType
    let fundConfig: FundConfig
    var existingEntries: [FundEntry] = []
    let onSaved: () -> Void

    @State private var date: Date
    @State private var action: FundAction
    @State private var value: String
    @State private var amount: String
    @State private var shares: String
    @State private var price: String
    @State private var dividend: String
    @State private var expense: String
    @State private var marginAvailable: String
    @State private var marginBorrowed: String
    @State private var notes: String
    @State private var fundSizeText: String
    @State private var cashInterest: String
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var showOptional = true

    private var isCash: Bool { fundType == .cash }

    init(entry: FundEntry, entryIndex: Int, fundId: String, fundType: FundType, fundConfig: FundConfig, existingEntries: [FundEntry] = [], onSaved: @escaping () -> Void) {
        self.entry = entry
        self.entryIndex = entryIndex
        self.fundId = fundId
        self.fundType = fundType
        self.fundConfig = fundConfig
        self.existingEntries = existingEntries
        self.onSaved = onSaved
        _date = State(initialValue: isoDateFormatter.date(from: entry.date) ?? Date())
        _action = State(initialValue: entry.action ?? .HOLD)
        // For cash funds, show the cash balance (cash ?? fund_size ?? value)
        let cashDisplay = fundType == .cash
            ? (entry.cash ?? entry.fund_size ?? entry.value)
            : entry.value
        _value = State(initialValue: cleanNum(cashDisplay))
        _amount = State(initialValue: cleanNum(entry.amount))
        _shares = State(initialValue: cleanShares(entry.shares))
        _price = State(initialValue: cleanShares(entry.price))
        _dividend = State(initialValue: cleanNum(entry.dividend))
        _expense = State(initialValue: cleanNum(entry.expense))
        _marginAvailable = State(initialValue: cleanNum(entry.margin_available))
        _marginBorrowed = State(initialValue: cleanNum(entry.margin_borrowed))
        _notes = State(initialValue: entry.notes ?? "")
        _fundSizeText = State(initialValue: cleanNum(entry.fund_size))
        _cashInterest = State(initialValue: cleanNum(entry.cash_interest))
    }

    private var features: FundTypeFeatures { getFeatures(fundType) }

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

                // MARK: - Delete
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Entry")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 400)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deleteEntry() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Cash Fund Form

    @ViewBuilder
    private var cashForm: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
        }

        Section {
            NumericFieldRow(label: "Cash Balance ($)", placeholder: "Current balance", text: $value)
            NumericFieldRow(label: "Amount ($)", placeholder: "Deposit/withdrawal", text: $amount)
        } header: {
            Text("Cash Balance Entry")
                .foregroundColor(.mint)
        }

        Section(isExpanded: $showOptional) {
            NumericFieldRow(label: "Interest Earned ($)", text: $cashInterest)
            NumericFieldRow(label: "Expense ($)", text: $expense, sign: "-")
            if features.supportsMargin {
                NumericFieldRow(label: "Margin Available ($)", text: $marginAvailable)
                NumericFieldRow(label: "Margin Borrowed ($)", text: $marginBorrowed, sign: "-")
            }
            TextField("Notes", text: $notes)
        } header: {
            Text("Optional")
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
            NumericFieldRow(label: "Expense ($)", text: $expense, sign: "-")
            if features.supportsMargin {
                NumericFieldRow(label: "Margin Available ($)", text: $marginAvailable)
                NumericFieldRow(label: "Margin Borrowed ($)", text: $marginBorrowed, sign: "-")
            }
            NumericFieldRow(label: "Fund Size ($)", text: $fundSizeText)
            TextField("Notes", text: $notes)
        } header: {
            Text("Optional")
        }
    }

    private func calcPriceEquity() {
        guard let result = calcPriceAndEquity(amount: amount, shares: shares, existingEntries: existingEntries, date: date, dollarDecimals: fundConfig.dollarDec) else { return }
        price = result.price
        if !result.value.isEmpty { value = result.value }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        var updated = entry
        updated.date = isoDateFormatter.string(from: date)
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let parsedValue = r(parseFormulaValue(value))

        if isCash {
            // Cash fund: value, cash, and fund_size are all the cash balance
            updated.value = parsedValue
            updated.cash = parsedValue > 0 ? parsedValue : nil
            updated.fund_size = parsedValue > 0 ? parsedValue : nil
            let amt = r(parseFormulaValue(amount)); updated.amount = amt != 0 ? abs(amt) : nil
            updated.action = amt > 0 ? .DEPOSIT : amt < 0 ? .WITHDRAW : entry.action
            let ci = r(parseFormulaValue(cashInterest)); updated.cash_interest = ci != 0 ? ci : nil
        } else {
            updated.value = parsedValue
            updated.action = action
            let amt = r(parseFormulaValue(amount)); updated.amount = amt != 0 ? amt : nil
            let sh = parseFormulaValue(shares); updated.shares = sh != 0 ? sh : nil
            let pr = parseFormulaValue(price); updated.price = pr != 0 ? pr : nil
            let div = r(parseFormulaValue(dividend)); updated.dividend = div != 0 ? div : nil
            let fs = r(parseFormulaValue(fundSizeText)); updated.fund_size = fs != 0 ? fs : nil
        }

        let exp = r(parseFormulaValue(expense)); updated.expense = exp != 0 ? exp : nil
        let mav = r(parseFormulaValue(marginAvailable)); updated.margin_available = mav != 0 ? mav : nil
        let mbr = r(parseFormulaValue(marginBorrowed)); updated.margin_borrowed = mbr != 0 ? mbr : nil
        updated.notes = notes.isEmpty ? nil : notes

        dismiss()
        Task {
            guard var fund = store.fund(byId: fundId) else { return }
            guard entryIndex >= 0 && entryIndex < fund.entries.count else { return }
            fund.entries[entryIndex] = updated
            await store.replaceEntries(fundId: fundId, entries: fund.entries)
            onSaved()
        }
    }

    private func deleteEntry() {
        dismiss()
        Task {
            guard var fund = store.fund(byId: fundId) else { return }
            guard entryIndex >= 0 && entryIndex < fund.entries.count else { return }
            fund.entries.remove(at: entryIndex)
            await store.replaceEntries(fundId: fundId, entries: fund.entries)
            onSaved()
        }
    }
}
