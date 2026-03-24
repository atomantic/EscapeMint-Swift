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
    @State private var showDeleteConfirm = false
    @State private var isSaving = false

    init(fund: FundData, onSaved: @escaping () -> Void, onDeleted: (() -> Void)? = nil) {
        self.fund = fund
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _platform = State(initialValue: fund.platform)
        _ticker = State(initialValue: fund.ticker)
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

                if isTradingFund {
                    Section("DCA Strategy") {
                        tipField("Target APY (%)", tip: DCAHelp.targetApy, text: $targetApy)
                        tipField("Interval (days)", tip: DCAHelp.interval, text: $intervalDays)
                    }

                    Section("DCA Amounts") {
                        tipField("Min ($) — at/above target", tip: DCAHelp.minDCA, text: $inputMin)
                        tipField("Mid ($) — below target", tip: DCAHelp.midDCA, text: $inputMid)
                        tipField("Max ($) — significant loss", tip: DCAHelp.maxDCA, text: $inputMax)
                        tipField("Max threshold (%)", tip: DCAHelp.maxThreshold, text: $maxAtPct)
                    }

                    Section("Sell & Cash") {
                        tipField("Min profit ($) to sell", tip: DCAHelp.minProfit, text: $minProfitUsd)
                        tipToggle("Accumulate mode", tip: DCAHelp.accumulate, isOn: $accumulate)
                        tipToggle("Manage cash in fund", tip: DCAHelp.manageCash, isOn: $manageCash)
                    }
                }

                Section {
                    Button("Delete Fund", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit \(fund.ticker.uppercased())")
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

        let platformChanged = platform != fund.platform
        let tickerChanged = ticker != fund.ticker

        dismiss()

        let store = FundDataStore.shared
        Task {
            if platformChanged || tickerChanged {
                var newFund = fund
                newFund.platform = platform
                newFund.ticker = ticker
                newFund.config = config
                await store.addFund(newFund)
                await store.deleteFund(id: fund.id)
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

    @ViewBuilder
    private func tipField(_ label: String, tip: String, text: Binding<String>) -> some View {
        HStack {
            InfoTipLabel(label: label, tip: tip)
            Spacer()
            TextField("0", text: text)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .numericKeyboard()
        }
    }

    @ViewBuilder
    private func tipToggle(_ label: String, tip: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            InfoTipLabel(label: label, tip: tip)
        }
    }
}
