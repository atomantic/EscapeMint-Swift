import SwiftUI

struct CreateFundView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var platform = ""
    @State private var ticker = ""
    @State private var fundType: FundType = .stock
    @State private var category: FundCategory = .volatility
    @State private var fundSize = ""
    @State private var targetApy = "10"
    @State private var inputMin = "100"
    @State private var inputMid = "150"
    @State private var inputMax = "200"
    @State private var intervalDays = "7"

    var body: some View {
        NavigationStack {
            Form {
                Section("Fund Identity") {
                    TextField("Platform (e.g. robinhood)", text: $platform)
                        .noAutoCapitalization()
                        .autocorrectionDisabled()
                    TextField("Ticker (e.g. TQQQ)", text: $ticker)
                        .uppercaseCapitalization()
                        .autocorrectionDisabled()
                }

                Section("Type & Category") {
                    Picker("Fund Type", selection: $fundType) {
                        ForEach(FundType.allCases, id: \.self) { type in
                            Text(getFeatures(type).label).tag(type)
                        }
                    }
                    .onChange(of: fundType) { _, newType in
                        if let defaults = fundTypeDefaults[newType] {
                            targetApy = String((defaults.target_apy ?? 0) * 100)
                            inputMin = String(Int(defaults.input_min_usd ?? 0))
                            inputMid = String(Int(defaults.input_mid_usd ?? 0))
                            inputMax = String(Int(defaults.input_max_usd ?? 0))
                            intervalDays = String(defaults.interval_days ?? 7)
                        }
                    }

                    if fundType != .cash {
                        Picker("Category", selection: $category) {
                            ForEach(FundCategory.allCases, id: \.self) { cat in
                                Text(categoryConfig[cat]?.label ?? cat.rawValue).tag(cat)
                            }
                        }
                    }
                }

                Section("Allocation") {
                    TextField("Fund Size (USD)", text: $fundSize)
                        .numericKeyboard()
                }

                if fundType != .cash && fundType != .derivatives {
                    Section("DCA Configuration") {
                        TextField("Target APY (%)", text: $targetApy)
                            .numericKeyboard()
                        TextField("Min DCA (performing well)", text: $inputMin)
                            .numericKeyboard()
                        TextField("Mid DCA (underperforming)", text: $inputMid)
                            .numericKeyboard()
                        TextField("Max DCA (significant loss)", text: $inputMax)
                            .numericKeyboard()
                        TextField("Interval (days)", text: $intervalDays)
                            .numberKeyboard()
                    }
                }
            }
            .navigationTitle("Create Fund")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { save() }
                        .disabled(platform.isEmpty || ticker.isEmpty || fundSize.isEmpty)
                }
            }
        }
    }

    private func save() {
        var config = fundTypeDefaults[fundType] ?? FundConfig()
        config.fund_type = fundType
        config.status = .active
        config.category = category
        config.fund_size_usd = Double(fundSize) ?? 0
        config.target_apy = (Double(targetApy) ?? 0) / 100
        config.input_min_usd = Double(inputMin) ?? 0
        config.input_mid_usd = Double(inputMid) ?? 0
        config.input_max_usd = Double(inputMax) ?? 0
        config.interval_days = Int(intervalDays) ?? 7

        let fund = FundData(
            platform: platform.lowercased().trimmingCharacters(in: .whitespaces),
            ticker: ticker.lowercased().trimmingCharacters(in: .whitespaces),
            config: config,
            entries: []
        )

        Task {
            try? await FundStore.shared.writeFund(fund)
            onCreated()
            dismiss()
        }
    }
}
