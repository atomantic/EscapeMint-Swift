import SwiftUI

struct EditFundView: View {
    @Environment(\.dismiss) private var dismiss
    let fund: FundData
    let onSaved: () -> Void
    var onDeleted: (() -> Void)?

    @State private var platform: String
    @State private var ticker: String
    @State private var targetApy: String
    @State private var inputMin: String
    @State private var inputMid: String
    @State private var inputMax: String
    @State private var intervalDays: String
    @State private var maxAtPct: String
    @State private var minProfitUsd: String
    @State private var category: FundCategory
    @State private var status: FundStatus
    @State private var accumulate: Bool
    @State private var manageCash: Bool
    @State private var marginEnabled: Bool
    @State private var dividendReinvest: Bool
    @State private var interestReinvest: Bool
    @State private var expenseFromFund: Bool
    @State private var dollarDecimals: String
    @State private var equityInput: EquityInputMethod
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var selectedTab = 0

    init(fund: FundData, onSaved: @escaping () -> Void, onDeleted: (() -> Void)? = nil) {
        self.fund = fund
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _platform = State(initialValue: fund.platform)
        _ticker = State(initialValue: fund.ticker)
        _targetApy = State(initialValue: cleanNum((fund.config.target_apy ?? 0) * 100))
        _inputMin = State(initialValue: cleanNum(fund.config.input_min_usd))
        _inputMid = State(initialValue: cleanNum(fund.config.input_mid_usd))
        _inputMax = State(initialValue: cleanNum(fund.config.input_max_usd))
        _intervalDays = State(initialValue: String(fund.config.interval_days ?? 7))
        _maxAtPct = State(initialValue: cleanNum((fund.config.max_at_pct ?? 0) * 100))
        _minProfitUsd = State(initialValue: cleanNum(fund.config.min_profit_usd))
        _category = State(initialValue: fund.config.category ?? .volatility)
        _status = State(initialValue: fund.config.status ?? .active)
        _accumulate = State(initialValue: fund.config.accumulate ?? true)
        _manageCash = State(initialValue: fund.config.manage_cash ?? false)
        _marginEnabled = State(initialValue: fund.config.margin_enabled ?? false)
        _dividendReinvest = State(initialValue: fund.config.dividend_reinvest ?? false)
        _interestReinvest = State(initialValue: fund.config.interest_reinvest ?? false)
        _expenseFromFund = State(initialValue: fund.config.expense_from_fund ?? false)
        _dollarDecimals = State(initialValue: fund.config.dollar_decimals.map(String.init) ?? "2")
        _equityInput = State(initialValue: fund.config.effectiveEquityInput)
    }

    private var isTradingFund: Bool {
        fund.config.fund_type?.isTradingType ?? false
    }

    private var features: FundTypeFeatures {
        getFeatures(fund.config.fund_type)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isTradingFund {
                    Picker("", selection: $selectedTab) {
                        Text("General").tag(0)
                        Text("DCA").tag(1)
                        Text("Options").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                switch selectedTab {
                case 0: generalTab
                case 1: dcaTab
                case 2: optionsTab
                default: generalTab
                }

                Section {
                    Button("Delete Fund", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit \(fund.ticker.uppercased())")
            #if os(macOS)
            .frame(minWidth: 420)
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
            .confirmationDialog("Delete \(fund.id)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteFund() }
            } message: {
                Text("This will permanently delete all entries and configuration.")
            }
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        Section("Identity") {
            TextField("Platform", text: $platform)
                .autocorrectionDisabled()
                .noAutoCapitalization()
            TextField("Ticker", text: $ticker)
                .autocorrectionDisabled()
                .noAutoCapitalization()
                .onChange(of: ticker) { _, newValue in
                    ticker = newValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                }
        }

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

        Section("Display") {
            dcaTipField("Dollar decimals", tip: "Number of decimal places for dollar values. Use 5 for low-price crypto like DOGE ($0.09424).", text: $dollarDecimals, placeholder: "2")
        }

        if !isCashFund(fund.config.fund_type) {
            Section {
                Picker("Equity input", selection: $equityInput) {
                    Text("Direct (enter portfolio value)").tag(EquityInputMethod.direct)
                    Text("Shares × price").tag(EquityInputMethod.shares_price)
                }
            } header: {
                Text("Guided Entry")
            } footer: {
                Text("Shares × price is useful for platforms like Crypto.com where you observe holdings and price separately rather than a portfolio value.")
            }
        }
    }

    @ViewBuilder
    private var dcaTab: some View {
        Section("DCA Strategy") {
            dcaTipField("Target APY (%)", tip: DCAHelp.targetApy, text: $targetApy)
            dcaTipField("Interval (days)", tip: DCAHelp.interval, text: $intervalDays)
        }

        Section("DCA Amounts") {
            dcaTipField("Min ($) — at/above target", tip: DCAHelp.minDCA, text: $inputMin)
            dcaTipField("Mid ($) — below target", tip: DCAHelp.midDCA, text: $inputMid)
            dcaTipField("Max ($) — significant loss", tip: DCAHelp.maxDCA, text: $inputMax)
            dcaTipField("Max threshold (%)", tip: DCAHelp.maxThreshold, text: $maxAtPct)
        }
    }

    @ViewBuilder
    private var optionsTab: some View {
        Section("Sell & Cash") {
            dcaTipField("Min profit ($) to sell", tip: DCAHelp.minProfit, text: $minProfitUsd)
            dcaTipToggle("Accumulate mode", tip: DCAHelp.accumulate, isOn: $accumulate)
            dcaTipToggle("Manage cash in fund", tip: DCAHelp.manageCash, isOn: $manageCash)
            if features.supportsMargin {
                dcaTipToggle("Margin enabled", tip: "Enable margin tracking for this fund", isOn: $marginEnabled)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true

        var config = fund.config
        config.target_apy = (Double(targetApy) ?? 0) / 100
        config.input_min_usd = Double(inputMin) ?? 0
        config.input_mid_usd = Double(inputMid) ?? 0
        config.input_max_usd = Double(inputMax) ?? 0
        config.interval_days = Int(intervalDays) ?? 7
        config.max_at_pct = (Double(maxAtPct) ?? 0) / 100
        config.min_profit_usd = Double(minProfitUsd) ?? 0
        config.category = category
        config.status = status
        config.accumulate = accumulate
        config.manage_cash = manageCash
        config.margin_enabled = marginEnabled
        config.dividend_reinvest = dividendReinvest
        config.interest_reinvest = interestReinvest
        config.expense_from_fund = expenseFromFund
        let dd = Int(dollarDecimals) ?? 2
        config.dollar_decimals = dd == 2 ? nil : dd
        config.equity_input = equityInput == .direct ? nil : equityInput

        let cleanPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanTicker = ticker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let platformChanged = cleanPlatform != fund.platform
        let tickerChanged = cleanTicker != fund.ticker

        dismiss()

        let store = FundDataStore.shared
        Task {
            if platformChanged || tickerChanged {
                var newFund = fund
                newFund.platform = cleanPlatform
                newFund.ticker = cleanTicker
                newFund.config = config
                await store.renameFund(from: fund.id, to: newFund)
            } else {
                await store.updateConfig(fundId: fund.id, config: config)
            }
            onSaved()
        }
    }

    private func deleteFund() {
        Task {
            await FundDataStore.shared.deleteFund(id: fund.id)
            dismiss()
            onDeleted?() ?? onSaved()
        }
    }

}
