import SwiftUI

struct AddEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let fundId: String
    let fundType: FundType
    let onSaved: () -> Void

    @State private var date = Date()
    @State private var action: FundAction = .BUY
    @State private var value = ""
    @State private var amount = ""
    @State private var shares = ""
    @State private var price = ""
    @State private var notes = ""

    private var actions: [FundAction] {
        allowedActions[fundType] ?? [.BUY, .SELL, .HOLD]
    }

    private var features: FundTypeFeatures {
        getFeatures(fundType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)

                    Picker("Action", selection: $action) {
                        ForEach(actions, id: \.self) { a in
                            Text(a.rawValue).tag(a)
                        }
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
                }

                Section("Notes") {
                    TextField("Optional notes", text: $notes)
                }
            }
            .navigationTitle("Add Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                action = actions.first ?? .BUY
            }
        }
    }

    private func save() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        var entry = FundEntry(
            date: fmt.string(from: date),
            value: Double(value) ?? 0,
            action: action
        )
        if let amt = Double(amount), amt != 0 { entry.amount = amt }
        if let s = Double(shares), s != 0 { entry.shares = s }
        if let p = Double(price), p != 0 { entry.price = p }
        if !notes.isEmpty { entry.notes = notes }

        Task {
            await FundDataStore.shared.appendEntry(fundId: fundId, entry: entry)
            onSaved()
            dismiss()
        }
    }
}
