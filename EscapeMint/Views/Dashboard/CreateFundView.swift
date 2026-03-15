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

    private var canCreate: Bool {
        !platform.isEmpty && !ticker.isEmpty && !fundSize.isEmpty
    }

    var body: some View {
        #if os(macOS)
        macForm
        #else
        NavigationStack { iosForm }
        #endif
    }

    // MARK: - macOS

    @ViewBuilder
    private var macForm: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Create Fund")
                    .font(.title3).fontWeight(.bold).foregroundColor(.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().background(Color.bgInput)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Fund Identity
                    formSection("Fund Identity") {
                        HStack(spacing: 12) {
                            formField("Platform", placeholder: "e.g. robinhood", text: $platform)
                                .noAutoCapitalization()
                                .autocorrectionDisabled()
                            formField("Ticker", placeholder: "e.g. TQQQ", text: $ticker)
                                .uppercaseCapitalization()
                                .autocorrectionDisabled()
                        }
                    }

                    // Type & Category
                    formSection("Type & Category") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Fund Type").font(.caption).foregroundColor(.textMuted)
                                Picker("", selection: $fundType) {
                                    ForEach(FundType.allCases, id: \.self) { type in
                                        Text(getFeatures(type).label).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Category").font(.caption).foregroundColor(.textMuted)
                                    Picker("", selection: $category) {
                                        ForEach(FundCategory.allCases, id: \.self) { cat in
                                            Text(categoryConfig[cat]?.label ?? cat.rawValue).tag(cat)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                        }
                    }

                    // Allocation
                    formSection("Allocation") {
                        formField("Fund Size (USD)", placeholder: "$0", text: $fundSize)
                            .frame(maxWidth: 200)
                    }

                    // DCA
                    if fundType != .cash && fundType != .derivatives {
                        formSection("DCA Configuration") {
                            HStack(spacing: 12) {
                                formField("Target APY (%)", placeholder: "10", text: $targetApy)
                                formField("Interval (days)", placeholder: "7", text: $intervalDays)
                            }
                            HStack(spacing: 12) {
                                formField("Min DCA", placeholder: "100", text: $inputMin)
                                formField("Mid DCA", placeholder: "150", text: $inputMid)
                                formField("Max DCA", placeholder: "200", text: $inputMax)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider().background(Color.bgInput)

            // Action bar
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Fund") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .buttonStyle(.borderedProminent)
                    .tint(.mint)
            }
            .padding(16)
        }
        .frame(width: 520, height: 480)
        .background(Color.bg)
    }

    // MARK: - iOS

    @ViewBuilder
    private var iosForm: some View {
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
                    .disabled(!canCreate)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func formSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption).fontWeight(.semibold).foregroundColor(.textSecondary)
            content()
        }
    }

    @ViewBuilder
    private func formField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.textMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.bgInput)
                .cornerRadius(6)
                .foregroundColor(.textPrimary)
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
            notifyFundsChanged()
            dismiss()
        }
    }
}
