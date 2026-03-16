import SwiftUI

struct EditEntryView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: FundDataStore { .shared }
    let entry: FundEntry
    let entryIndex: Int
    let fundId: String
    let fundType: FundType
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
    @State private var showDeleteConfirm = false

    init(entry: FundEntry, entryIndex: Int, fundId: String, fundType: FundType, onSaved: @escaping () -> Void) {
        self.entry = entry
        self.entryIndex = entryIndex
        self.fundId = fundId
        self.fundType = fundType
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

    private var actions: [FundAction] { allowedActions[fundType] ?? [.BUY, .SELL, .HOLD] }
    private var features: FundTypeFeatures { getFeatures(fundType) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Action", selection: $action) {
                        ForEach(actions, id: \.self) { a in Text(a.rawValue).tag(a) }
                    }
                }
                Section {
                    NumericFieldRow(label: "Portfolio Value", text: $value)
                    if action == .BUY || action == .SELL || action == .DEPOSIT || action == .WITHDRAW {
                        NumericFieldRow(label: "Amount", text: $amount)
                    }
                    if features.supportsShares && (action == .BUY || action == .SELL) {
                        NumericFieldRow(label: "Shares", placeholder: "0", text: $shares)
                        NumericFieldRow(label: "Price per Share", text: $price)
                    }
                    if features.supportsDividends {
                        NumericFieldRow(label: "Dividend", text: $dividend)
                    }
                } header: {
                    Text("Values")
                }
                Section {
                    TextField("Optional notes", text: $notes)
                } header: {
                    Text("Notes")
                }
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
            .frame(minWidth: 420, minHeight: 350)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { deleteEntry() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func save() {
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

        Task {
            guard var fund = store.fund(byId: fundId) else { return }
            guard entryIndex >= 0 && entryIndex < fund.entries.count else { return }
            fund.entries[entryIndex] = updated
            await store.replaceEntries(fundId: fundId, entries: fund.entries)
            onSaved()
            dismiss()
        }
    }

    private func deleteEntry() {
        Task {
            guard var fund = store.fund(byId: fundId) else { return }
            guard entryIndex >= 0 && entryIndex < fund.entries.count else { return }
            fund.entries.remove(at: entryIndex)
            await store.replaceEntries(fundId: fundId, entries: fund.entries)
            onSaved()
            dismiss()
        }
    }
}
