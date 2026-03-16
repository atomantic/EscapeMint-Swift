import SwiftUI

struct EditFundView: View {
    @Environment(\.dismiss) private var dismiss
    let fund: FundData
    let onSaved: () -> Void
    var onDeleted: (() -> Void)?

    @State private var platform: String
    @State private var ticker: String
    @State private var fundSize: String
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
    @State private var marginApr: String
    @State private var marginAccessUsd: String
    @State private var dividendReinvest: Bool
    @State private var interestReinvest: Bool
    @State private var expenseFromFund: Bool
    @State private var showDeleteConfirm = false

    init(fund: FundData, onSaved: @escaping () -> Void, onDeleted: (() -> Void)? = nil) {
        self.fund = fund
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _platform = State(initialValue: fund.platform)
        _ticker = State(initialValue: fund.ticker)
        _fundSize = State(initialValue: String(fund.config.fund_size_usd ?? 0))
        _targetApy = State(initialValue: String((fund.config.target_apy ?? 0) * 100))
        _inputMin = State(initialValue: String(fund.config.input_min_usd ?? 0))
        _inputMid = State(initialValue: String(fund.config.input_mid_usd ?? 0))
        _inputMax = State(initialValue: String(fund.config.input_max_usd ?? 0))
        _intervalDays = State(initialValue: String(fund.config.interval_days ?? 7))
        _maxAtPct = State(initialValue: String((fund.config.max_at_pct ?? 0) * 100))
        _minProfitUsd = State(initialValue: String(fund.config.min_profit_usd ?? 0))
        _category = State(initialValue: fund.config.category ?? .volatility)
        _status = State(initialValue: fund.config.status ?? .active)
        _accumulate = State(initialValue: fund.config.accumulate ?? true)
        _manageCash = State(initialValue: fund.config.manage_cash ?? false)
        _marginEnabled = State(initialValue: fund.config.margin_enabled ?? false)
        _marginApr = State(initialValue: String((fund.config.margin_apr ?? 0) * 100))
        _marginAccessUsd = State(initialValue: String(fund.config.margin_access_usd ?? 0))
        _dividendReinvest = State(initialValue: fund.config.dividend_reinvest ?? false)
        _interestReinvest = State(initialValue: fund.config.interest_reinvest ?? false)
        _expenseFromFund = State(initialValue: fund.config.expense_from_fund ?? false)
    }

    private var isTradingFund: Bool {
        fund.config.fund_type == .stock || fund.config.fund_type == .crypto
    }

    private var features: FundTypeFeatures {
        getFeatures(fund.config.fund_type)
    }

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Allocation") {
                    TextField("Fund Size (USD)", text: $fundSize)
                        .numericKeyboard()
                }

                if isTradingFund {
                    Section("Trading Configuration") {
                        TextField("Target APY (%)", text: $targetApy)
                            .numericKeyboard()
                        TextField("Interval (days)", text: $intervalDays)
                            .numberKeyboard()
                        TextField("Min DCA", text: $inputMin)
                            .numericKeyboard()
                        TextField("Mid DCA", text: $inputMid)
                            .numericKeyboard()
                        TextField("Max DCA", text: $inputMax)
                            .numericKeyboard()
                        TextField("Max DCA Threshold (%)", text: $maxAtPct)
                            .numericKeyboard()
                        TextField("Min Profit to Sell (USD)", text: $minProfitUsd)
                            .numericKeyboard()
                    }
                }

                Section("Features") {
                    Toggle("Accumulate", isOn: $accumulate)
                    Toggle("Manage Cash", isOn: $manageCash)
                    if features.supportsMargin {
                        Toggle("Margin Trading", isOn: $marginEnabled)
                    }
                    if features.supportsDividends {
                        Toggle("Dividend Reinvestment", isOn: $dividendReinvest)
                    }
                    if features.supportsCashInterest {
                        Toggle("Interest Reinvestment", isOn: $interestReinvest)
                    }
                    Toggle("Expense From Fund", isOn: $expenseFromFund)
                }

                if marginEnabled && features.supportsMargin {
                    Section("Margin Settings") {
                        TextField("Margin APR (%)", text: $marginApr)
                            .numericKeyboard()
                        TextField("Margin Access (USD)", text: $marginAccessUsd)
                            .numericKeyboard()
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
        config.max_at_pct = (Double(maxAtPct) ?? 0) / 100
        config.min_profit_usd = Double(minProfitUsd) ?? 0
        config.category = category
        config.status = status
        config.accumulate = accumulate
        config.manage_cash = manageCash
        config.margin_enabled = marginEnabled
        config.margin_apr = (Double(marginApr) ?? 0) / 100
        config.margin_access_usd = Double(marginAccessUsd) ?? 0
        config.dividend_reinvest = dividendReinvest
        config.interest_reinvest = interestReinvest
        config.expense_from_fund = expenseFromFund

        let platformChanged = platform != fund.platform
        let tickerChanged = ticker != fund.ticker

        let store = FundDataStore.shared
        Task {
            if platformChanged || tickerChanged {
                // Identity changed — write as new fund and delete old, then full reload
                var newFund = fund
                newFund.platform = platform
                newFund.ticker = ticker
                newFund.config = config
                try? await FundStore.shared.writeFund(newFund)
                try? await FundStore.shared.deleteFund(id: fund.id)
                await store.reload()
            } else {
                await store.updateConfig(fundId: fund.id, config: config)
            }
            onSaved()
            dismiss()
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
