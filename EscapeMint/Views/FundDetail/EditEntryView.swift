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
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var showOptional = true

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
        _value = State(initialValue: String(entry.value))
        _amount = State(initialValue: entry.amount.map { String($0) } ?? "")
        _shares = State(initialValue: entry.shares.map { String($0) } ?? "")
        _price = State(initialValue: entry.price.map { String($0) } ?? "")
        _dividend = State(initialValue: entry.dividend.map { String($0) } ?? "")
        _expense = State(initialValue: entry.expense.map { String($0) } ?? "")
        _marginAvailable = State(initialValue: entry.margin_available.map { String($0) } ?? "")
        _marginBorrowed = State(initialValue: entry.margin_borrowed.map { String($0) } ?? "")
        _notes = State(initialValue: entry.notes ?? "")
        _fundSizeText = State(initialValue: entry.fund_size.map { String($0) } ?? "")
    }

    private var features: FundTypeFeatures { getFeatures(fundType) }

    private var totalSharesHint: String? {
        formatSharesHint(getTotalShares(entries: existingEntries))
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Action section
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Action", selection: $action) {
                        Text("BUY").tag(FundAction.BUY)
                        Text("SELL").tag(FundAction.SELL)
                        Text("HOLD").tag(FundAction.HOLD)
                    }
                }

                // MARK: - Values section
                Section {
                    NumericFieldRow(label: "Equity ($)", placeholder: "Portfolio value", text: $value)
                    NumericFieldRow(label: "Amount ($)", placeholder: action == .HOLD ? "N/A" : "Buy/sell amount", text: $amount)
                        .disabled(action == .HOLD)
                        .opacity(action == .HOLD ? 0.5 : 1)
                } header: {
                    Text("Action")
                }

                // MARK: - Optional section
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

    private func calcPriceEquity() {
        guard let result = calcPriceAndEquity(amount: amount, shares: shares, existingEntries: existingEntries, date: date) else { return }
        price = result.price
        if !result.value.isEmpty { value = result.value }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        var updated = entry
        updated.date = isoDateFormatter.string(from: date)
        updated.value = parseFormulaValue(value)
        updated.action = action
        let amt = parseFormulaValue(amount); updated.amount = amt != 0 ? amt : nil
        let sh = parseFormulaValue(shares); updated.shares = sh != 0 ? sh : nil
        let pr = parseFormulaValue(price); updated.price = pr != 0 ? pr : nil
        let div = parseFormulaValue(dividend); updated.dividend = div != 0 ? div : nil
        let exp = parseFormulaValue(expense); updated.expense = exp != 0 ? exp : nil
        let mav = parseFormulaValue(marginAvailable); updated.margin_available = mav != 0 ? mav : nil
        let mbr = parseFormulaValue(marginBorrowed); updated.margin_borrowed = mbr != 0 ? mbr : nil
        updated.notes = notes.isEmpty ? nil : notes

        let fs = parseFormulaValue(fundSizeText); updated.fund_size = fs != 0 ? fs : nil

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
