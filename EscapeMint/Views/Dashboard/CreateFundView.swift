import SwiftUI

struct CreateFundView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var platform = ""
    @State private var ticker = ""
    @State private var fundType: FundType = .stock
    @State private var category: FundCategory = .volatility
    @State private var targetApy = "25"
    @State private var inputMin = "100"
    @State private var inputMid = "150"
    @State private var inputMax = "200"
    @State private var intervalDays = "7"
    @State private var minProfit = "100"
    @State private var maxAtPct = "-25"
    @State private var accumulate = true
    @State private var manageCash = false
    @State private var marginEnabled = false
    @State private var cashBalance = ""
    @State private var selectedTab = 0

    init(initialPlatform: String = "", onCreated: @escaping () -> Void) {
        self.onCreated = onCreated
        _platform = State(initialValue: initialPlatform.lowercased().trimmingCharacters(in: .whitespaces))
    }

    private var canCreate: Bool {
        !platform.isEmpty && !ticker.isEmpty
    }

    private var isTradingFund: Bool {
        fundType.isTradingType
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

    // MARK: - Shared Form Content

    @ViewBuilder
    private var identitySection: some View {
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
                selectedTab = 0
            }

            if fundType != .cash {
                Picker("Category", selection: $category) {
                    ForEach(FundCategory.allCases, id: \.self) { cat in
                        Text(categoryConfig[cat]?.label ?? cat.rawValue).tag(cat)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dcaSection: some View {
        Section("DCA Strategy") {
            dcaTipField("Target APY (%)", tip: DCAHelp.targetApy, text: $targetApy, placeholder: "25")
            dcaTipField("Interval (days)", tip: DCAHelp.interval, text: $intervalDays, placeholder: "7")
        }

        Section("DCA Amounts") {
            dcaTipField("Min ($) — at/above target", tip: DCAHelp.minDCA, text: $inputMin, placeholder: "100")
            dcaTipField("Mid ($) — below target", tip: DCAHelp.midDCA, text: $inputMid, placeholder: "150")
            dcaTipField("Max ($) — significant loss", tip: DCAHelp.maxDCA, text: $inputMax, placeholder: "200")
            dcaTipField("Max threshold (%)", tip: DCAHelp.maxThreshold, text: $maxAtPct, placeholder: "-25")
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section("Sell & Cash") {
            dcaTipField("Min profit ($) to sell", tip: DCAHelp.minProfit, text: $minProfit, placeholder: "100")
            dcaTipToggle("Accumulate mode", tip: DCAHelp.accumulate, isOn: $accumulate)
            dcaTipToggle("Manage cash in fund", tip: DCAHelp.manageCash, isOn: $manageCash)
            if getFeatures(fundType).supportsMargin {
                dcaTipToggle("Margin enabled", tip: "Enable margin tracking for this fund", isOn: $marginEnabled)
            }
        }

        if needsPlatformCash && !platformCashExists && !platform.isEmpty {
            Section {
                dcaTipField("Cash balance ($)", tip: "Starting cash available for DCA purchases on this platform.", text: $cashBalance, placeholder: "0")
            } header: {
                Text("Platform Cash")
            } footer: {
                Text("A cash fund will be created for \(platform) to track available cash.")
            }
        }
    }

    @ViewBuilder
    private var tabbedDCAOptions: some View {
        Picker("", selection: $selectedTab) {
            Text("DCA").tag(0)
            Text("Options").tag(1)
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        switch selectedTab {
        case 0: dcaSection
        case 1: optionsSection
        default: dcaSection
        }
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

            Form {
                identitySection
                if isTradingFund { tabbedDCAOptions }
            }
            .formStyle(.grouped)

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
        .frame(minWidth: 520, idealWidth: 520, minHeight: 520, idealHeight: 580)
        .background(Color.bg)
    }

    // MARK: - iOS

    @ViewBuilder
    private var iosForm: some View {
        Form {
            identitySection
            if isTradingFund { tabbedDCAOptions }
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

    // MARK: - Helpers

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
        config.margin_enabled = marginEnabled

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
