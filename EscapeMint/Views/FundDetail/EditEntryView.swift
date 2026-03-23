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
    @State private var notes: String
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
        _notes = State(initialValue: entry.notes ?? "")
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
                    NumericFieldRow(label: "Expense ($)", text: $expense)
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
        guard let amountVal = Double(amount), amountVal > 0,
              let sharesVal = Double(shares), sharesVal > 0 else { return }

        let selectedDate = isoDateFormatter.string(from: date)
        let calculatedPrice = amountVal / abs(sharesVal)
        price = String(format: "%.8f", calculatedPrice)

        let prior = getCumulativeShares(entries: existingEntries, beforeDate: selectedDate)
        if prior > 0 {
            let equity = prior * calculatedPrice
            value = String(format: "%.2f", equity)
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        var updated = entry
        updated.date = isoDateFormatter.string(from: date)
        updated.value = Double(value) ?? 0
        updated.action = action
        updated.amount = Double(amount)
        updated.shares = Double(shares)
        updated.price = Double(price)
        updated.dividend = Double(dividend)
        updated.expense = Double(expense)
        updated.notes = notes.isEmpty ? nil : notes

        // Compute fund_size — use other entries excluding this one being edited
        let otherEntries = existingEntries.enumerated().compactMap { $0.offset != entryIndex ? $0.element : nil }
        updated.fund_size = computeFundSizeForEntry(updated, existingEntries: otherEntries, config: fundConfig)

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
