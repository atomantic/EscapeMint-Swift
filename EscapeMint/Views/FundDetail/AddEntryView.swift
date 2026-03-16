import SwiftUI

struct NumericFieldRow: View {
    let label: String
    var placeholder: String = "0.00"
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: $text)
                .numericKeyboard()
                .multilineTextAlignment(.trailing)
                #if os(macOS)
                .frame(maxWidth: 200)
                #endif
        }
    }
}

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
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Action", selection: $action) {
                        ForEach(actions, id: \.self) { a in
                            Text(a.rawValue).tag(a)
                        }
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
                } header: {
                    Text("Values")
                }
                Section {
                    TextField("Optional notes", text: $notes)
                } header: {
                    Text("Notes")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Entry")
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 300)
            #endif
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
        var entry = FundEntry(
            date: isoDateFormatter.string(from: date),
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
