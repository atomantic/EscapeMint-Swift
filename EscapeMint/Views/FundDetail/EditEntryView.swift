import SwiftUI

struct EditEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: FundEntry
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(entry: FundEntry, fundId: String, fundType: FundType, onSaved: @escaping () -> Void) {
        self.entry = entry
        self.fundId = fundId
        self.fundType = fundType
        self.onSaved = onSaved
        _date = State(initialValue: Self.dateFormatter.date(from: entry.date) ?? Date())
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
                Section("Entry") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Action", selection: $action) {
                        ForEach(actions, id: \.self) { a in Text(a.rawValue).tag(a) }
                    }
                }
                Section("Values") {
                    TextField("Portfolio Value (USD)", text: $value)
                        .numericKeyboard()
                    if action == .BUY || action == .SELL || action == .DEPOSIT || action == .WITHDRAW {
                        TextField("Amount (USD)", text: $amount)
                            .numericKeyboard()
                    }
                    if features.supportsShares && (action == .BUY || action == .SELL) {
                        TextField("Shares", text: $shares)
                            .numericKeyboard()
                        TextField("Price per Share", text: $price)
                            .numericKeyboard()
                    }
                    if features.supportsDividends {
                        TextField("Dividend", text: $dividend)
                            .numericKeyboard()
                    }
                }
                Section("Notes") {
                    TextField("Optional notes", text: $notes)
                }
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Entry")
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
        let fmt = Self.dateFormatter
        var updated = entry
        updated.date = fmt.string(from: date)
        updated.value = Double(value) ?? 0
        updated.action = action
        updated.amount = Double(amount)
        updated.shares = Double(shares)
        updated.price = Double(price)
        updated.dividend = Double(dividend)
        updated.expense = Double(expense)
        updated.notes = notes.isEmpty ? nil : notes

        Task {
            guard var fund = await FundStore.shared.readFundById(fundId) else { return }
            if let idx = fund.entries.firstIndex(where: { $0.id == entry.id }) {
                fund.entries[idx] = updated
            }
            try? await FundStore.shared.replaceEntries(fundId: fundId, entries: fund.entries)
            onSaved()
            notifyFundsChanged()
            dismiss()
        }
    }

    private func deleteEntry() {
        Task {
            guard var fund = await FundStore.shared.readFundById(fundId) else { return }
            fund.entries.removeAll { $0.id == entry.id }
            try? await FundStore.shared.replaceEntries(fundId: fundId, entries: fund.entries)
            onSaved()
            notifyFundsChanged()
            dismiss()
        }
    }
}
