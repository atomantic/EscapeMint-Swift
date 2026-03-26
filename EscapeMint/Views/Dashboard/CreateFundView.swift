import SwiftUI

struct CreateFundView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var platform = ""
    @State private var ticker = ""
    @State private var fundType: FundType = .stock
    @State private var category: FundCategory = .volatility
    @State private var targetApy = "10"
    @State private var inputMin = "100"
    @State private var inputMid = "150"
    @State private var inputMax = "200"
    @State private var intervalDays = "7"
    @State private var minProfit = "100"
    @State private var maxAtPct = "-25"
    @State private var accumulate = true
    @State private var manageCash = false
    @State private var cashBalance = ""

    private var canCreate: Bool {
        !platform.isEmpty && !ticker.isEmpty
    }

    /// Whether this fund needs a platform cash fund created alongside it
    private var needsPlatformCash: Bool {
        fundType != .cash && !manageCash
    }

    /// Whether a cash fund already exists for the entered platform
    private var platformCashExists: Bool {
        let p = platform.lowercased().trimmingCharacters(in: .whitespaces)
        return FundDataStore.shared.funds.contains { $0.platform.lowercased() == p && $0.config.fund_type == .cash }
    }

    var body: some View {
        #if os(macOS)
        macForm
        #else
        NavigationStack { iosForm }
        #endif
    }

    // MARK: - Auto-category

    private func autoCategory(for t: String) -> FundCategory {
        let lower = t.lowercased()
        if lower == "btc" || lower == "bitcoin" { return .sov }
        if lower == "strc" { return .yield }
        if lower == "cash" || lower == "savings" { return .liquidity }
        return .volatility
    }

    // MARK: - macOS

    @ViewBuilder
    private var macForm: some View {
        VStack(spacing: 0) {
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
                    formSection("Fund Identity") {
                        HStack(spacing: 12) {
                            formField("Platform", placeholder: "e.g. robinhood", text: $platform)
                                .noAutoCapitalization()
                                .autocorrectionDisabled()
                            formField("Ticker", placeholder: "e.g. TQQQ", text: $ticker)
                                .uppercaseCapitalization()
                                .autocorrectionDisabled()
                                .onChange(of: ticker) { _, newTicker in
                                    category = autoCategory(for: newTicker)
                                }
                        }
                    }

                    formSection("Type & Category") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Fund Type").font(.caption).foregroundColor(.textMuted)
                                Picker("", selection: $fundType) {
                                    ForEach(FundType.creatableCases, id: \.self) { type in
                                        Text(getFeatures(type).label).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                            .onChange(of: fundType) { _, newType in
                                applyDefaults(for: newType)
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

                    if fundType != .cash && fundType != .derivatives {
                        formSection("DCA Configuration") {
                            HStack(spacing: 12) {
                                formField("Target APY (%)", placeholder: "10", text: $targetApy)
                                formField("Interval (days)", placeholder: "7", text: $intervalDays)
                            }
                            HStack(spacing: 12) {
                                formField("Min DCA ($)", placeholder: "100", text: $inputMin)
                                formField("Mid DCA ($)", placeholder: "150", text: $inputMid)
                                formField("Max DCA ($)", placeholder: "200", text: $inputMax)
                            }
                            HStack(spacing: 12) {
                                formField("Max Threshold (%)", placeholder: "-25", text: $maxAtPct)
                                formField("Min Profit ($)", placeholder: "100", text: $minProfit)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider().background(Color.bgInput)

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
        .frame(minWidth: 520, idealWidth: 520, minHeight: 480, idealHeight: 480)
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
                    .onChange(of: ticker) { _, newTicker in
                        category = autoCategory(for: newTicker)
                    }
            }

            Section("Type & Category") {
                Picker("Fund Type", selection: $fundType) {
                    ForEach(FundType.creatableCases, id: \.self) { type in
                        Text(getFeatures(type).label).tag(type)
                    }
                }
                .onChange(of: fundType) { _, newType in
                    applyDefaults(for: newType)
                }

                if fundType != .cash {
                    Picker("Category", selection: $category) {
                        ForEach(FundCategory.allCases, id: \.self) { cat in
                            Text(categoryConfig[cat]?.label ?? cat.rawValue).tag(cat)
                        }
                    }
                }
            }

            if fundType != .cash && fundType != .derivatives {
                Section("DCA Strategy") {
                    dcaTipField("Target APY (%)", tip: DCAHelp.targetApy, text: $targetApy, prompt: "10")
                    dcaTipField("Interval (days)", tip: DCAHelp.interval, text: $intervalDays, prompt: "7")
                }

                Section("DCA Amounts") {
                    dcaTipField("Min ($) — at/above target", tip: DCAHelp.minDCA, text: $inputMin, prompt: "100")
                    dcaTipField("Mid ($) — below target", tip: DCAHelp.midDCA, text: $inputMid, prompt: "150")
                    dcaTipField("Max ($) — significant loss", tip: DCAHelp.maxDCA, text: $inputMax, prompt: "200")
                    dcaTipField("Max threshold (%)", tip: DCAHelp.maxThreshold, text: $maxAtPct, prompt: "-25")
                }

                Section("Sell & Cash") {
                    dcaTipField("Min profit ($) to sell", tip: DCAHelp.minProfit, text: $minProfit, prompt: "100")
                    dcaTipToggle("Accumulate mode", tip: DCAHelp.accumulate, isOn: $accumulate)
                    dcaTipToggle("Manage cash in fund", tip: DCAHelp.manageCash, isOn: $manageCash)
                }
            }

            if needsPlatformCash && !platformCashExists && !platform.isEmpty {
                Section {
                    dcaTipField("Cash balance ($)", tip: "Starting cash available for DCA purchases on this platform.", text: $cashBalance, prompt: "0")
                } header: {
                    Text("Platform Cash")
                } footer: {
                    Text("A cash fund will be created for \(platform) to track your available cash for DCA purchases.")
                }
            }
        }
        .formStyle(.grouped)
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

    // MARK: - Shared helpers


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

    private func applyDefaults(for newType: FundType) {
        guard let defaults = fundTypeDefaults[newType] else { return }
        targetApy = String(Int((defaults.target_apy ?? 0) * 100))
        inputMin = String(Int(defaults.input_min_usd ?? 0))
        inputMid = String(Int(defaults.input_mid_usd ?? 0))
        inputMax = String(Int(defaults.input_max_usd ?? 0))
        intervalDays = String(defaults.interval_days ?? 7)
        minProfit = String(Int(defaults.min_profit_usd ?? 0))
        let pct = (defaults.max_at_pct ?? 0) * 100
        maxAtPct = String(Int(pct))
        accumulate = defaults.accumulate ?? true
        manageCash = defaults.manage_cash ?? true
    }

    private func save() {
        var config = fundTypeDefaults[fundType] ?? FundConfig()
        config.fund_type = fundType
        config.status = .active
        config.category = fundType == .cash ? .liquidity : category
        config.target_apy = (Double(targetApy) ?? 0) / 100
        config.input_min_usd = Double(inputMin) ?? 0
        config.input_mid_usd = Double(inputMid) ?? 0
        config.input_max_usd = Double(inputMax) ?? 0
        config.interval_days = Int(intervalDays) ?? 7
        config.min_profit_usd = Double(minProfit) ?? 0
        config.max_at_pct = (Double(maxAtPct) ?? 0) / 100
        config.accumulate = accumulate
        config.manage_cash = manageCash

        let fund = FundData(
            platform: platform.lowercased().trimmingCharacters(in: .whitespaces),
            ticker: ticker.lowercased().trimmingCharacters(in: .whitespaces),
            config: config,
            entries: []
        )

        Task {
            await FundDataStore.shared.addFund(fund)

            // Auto-create platform cash fund if needed
            if needsPlatformCash && !platformCashExists {
                let cashPlatform = fund.platform
                var cashConfig = fundTypeDefaults[.cash] ?? FundConfig()
                cashConfig.fund_type = .cash
                cashConfig.status = .active
                cashConfig.category = .liquidity
                let balance = Double(cashBalance) ?? 0
                var cashFund = FundData(
                    platform: cashPlatform,
                    ticker: "cash",
                    config: cashConfig,
                    entries: []
                )
                if balance > 0 {
                    cashFund.entries = [FundEntry(date: todayString(), value: balance, cash: balance, action: .DEPOSIT, amount: balance, fund_size: balance)]
                }
                await FundDataStore.shared.addFund(cashFund)
            }

            onCreated()
            dismiss()
        }
    }
}
