import SwiftUI

struct EditFundView: View {
    @Environment(\.dismiss) private var dismiss
    let fund: FundData
    let onSaved: () -> Void

    @State private var fundSize: String
    @State private var targetApy: String
    @State private var inputMin: String
    @State private var inputMid: String
    @State private var inputMax: String
    @State private var intervalDays: String
    @State private var category: FundCategory
    @State private var status: FundStatus
    @State private var showDeleteConfirm = false

    init(fund: FundData, onSaved: @escaping () -> Void) {
        self.fund = fund
        self.onSaved = onSaved
        _fundSize = State(initialValue: String(fund.config.fund_size_usd ?? 0))
        _targetApy = State(initialValue: String((fund.config.target_apy ?? 0) * 100))
        _inputMin = State(initialValue: String(fund.config.input_min_usd ?? 0))
        _inputMid = State(initialValue: String(fund.config.input_mid_usd ?? 0))
        _inputMax = State(initialValue: String(fund.config.input_max_usd ?? 0))
        _intervalDays = State(initialValue: String(fund.config.interval_days ?? 7))
        _category = State(initialValue: fund.config.category ?? .volatility)
        _status = State(initialValue: fund.config.status ?? .active)
    }

    private var isTradingFund: Bool {
        fund.config.fund_type == .stock || fund.config.fund_type == .crypto
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        Text("Active").tag(FundStatus.active)
                        Text("Closed").tag(FundStatus.closed)
                    }
                    Picker("Category", selection: $category) {
                        ForEach(FundCategory.allCases, id: \.self) { cat in
                            Text(categoryConfig[cat]?.label ?? cat.rawValue).tag(cat)
                        }
                    }
                }

                Section("Allocation") {
                    TextField("Fund Size (USD)", text: $fundSize)
                        .numericKeyboard()
                }

                if isTradingFund {
                    Section("DCA Configuration") {
                        TextField("Target APY (%)", text: $targetApy)
                            .numericKeyboard()
                        TextField("Min DCA", text: $inputMin)
                            .numericKeyboard()
                        TextField("Mid DCA", text: $inputMid)
                            .numericKeyboard()
                        TextField("Max DCA", text: $inputMax)
                            .numericKeyboard()
                        TextField("Interval (days)", text: $intervalDays)
                            .numberKeyboard()
                    }
                }

                Section {
                    Button("Delete Fund", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Edit \(fund.ticker.uppercased())")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .confirmationDialog("Delete \(fund.id)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteFund() }
            } message: {
                Text("This will permanently delete all entries and configuration.")
            }
        }
    }

    private func save() {
        var config = fund.config
        config.fund_size_usd = Double(fundSize) ?? 0
        config.target_apy = (Double(targetApy) ?? 0) / 100
        config.input_min_usd = Double(inputMin) ?? 0
        config.input_mid_usd = Double(inputMid) ?? 0
        config.input_max_usd = Double(inputMax) ?? 0
        config.interval_days = Int(intervalDays) ?? 7
        config.category = category
        config.status = status

        Task {
            try? await FundStore.shared.updateConfig(fundId: fund.id, config: config)
            onSaved()
            dismiss()
        }
    }

    private func deleteFund() {
        Task {
            try? await FundStore.shared.deleteFund(id: fund.id)
            onSaved()
            dismiss()
        }
    }
}
