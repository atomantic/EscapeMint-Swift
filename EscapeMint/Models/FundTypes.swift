import Foundation

enum FundType: String, Codable, CaseIterable {
    case cash
    case stock
    case crypto
    case derivatives

    /// Fund types available for user creation (derivatives is hidden/internal)
    static let creatableCases = allCases.filter { $0 != .derivatives }
}

enum FundStatus: String, Codable {
    case active
    case closed
}

enum FundCategory: String, Codable, CaseIterable {
    case liquidity
    case yield
    case sov
    case volatility
}

enum FundAction: String, Codable, CaseIterable {
    case BUY, SELL, HOLD, DEPOSIT, WITHDRAW, MARGIN
    case FUNDING, INTEREST, REBATE, FEE
}

struct FundConfig: Codable {
    // Metadata (prefixed with __ in JSON)
    var platform: String?
    var ticker: String?

    // Core
    var fund_type: FundType?
    var status: FundStatus?
    var category: FundCategory?
    var fund_size_usd: Double?
    var target_apy: Double?
    var interval_days: Int?

    // DCA
    var input_min_usd: Double?
    var input_mid_usd: Double?
    var input_max_usd: Double?
    var max_at_pct: Double?
    var min_profit_usd: Double?

    // Cash
    var cash_apy: Double?
    var manage_cash: Bool?

    // Margin
    var margin_enabled: Bool?

    // Behavior
    var accumulate: Bool?
    var dividend_reinvest: Bool?
    var interest_reinvest: Bool?
    var expense_from_fund: Bool?

    // Derivatives
    var initial_margin_rate: Double?
    var maintenance_margin_rate: Double?
    var contract_multiplier: Double?

    // Chart bounds (persisted per-fund)
    var chart_bounds: [String: ChartBounds]?

    enum CodingKeys: String, CodingKey {
        case platform = "__platform"
        case ticker = "__ticker"
        case fund_type, status, category
        case fund_size_usd, target_apy, interval_days
        case input_min_usd, input_mid_usd, input_max_usd
        case max_at_pct, min_profit_usd
        case cash_apy, manage_cash
        case margin_enabled
        case accumulate, dividend_reinvest, interest_reinvest, expense_from_fund
        case initial_margin_rate, maintenance_margin_rate, contract_multiplier
        case chart_bounds
    }
}

struct ChartBounds: Codable, Equatable {
    var yMin: Double?
    var yMax: Double?

    var isEmpty: Bool { yMin == nil && yMax == nil }
}

struct FundEntry: Identifiable {
    let id: String
    var date: String
    var value: Double
    var cash: Double?
    var action: FundAction?
    var amount: Double?
    var shares: Double?
    var price: Double?
    var dividend: Double?
    var expense: Double?
    var cash_interest: Double?
    var fund_size: Double?
    var margin_available: Double?
    var margin_borrowed: Double?
    var margin_expense: Double?
    var notes: String?
    var contracts: Double?
    var entry_price: Double?
    var liquidation_price: Double?
    var unrealized_pnl: Double?
    var margin_locked: Double?
    var fee: Double?
    var margin: Double?

    init(date: String, value: Double, cash: Double? = nil, action: FundAction? = nil,
         amount: Double? = nil, shares: Double? = nil, price: Double? = nil,
         dividend: Double? = nil, expense: Double? = nil, cash_interest: Double? = nil,
         fund_size: Double? = nil, margin_available: Double? = nil, margin_borrowed: Double? = nil,
         margin_expense: Double? = nil, notes: String? = nil, contracts: Double? = nil,
         entry_price: Double? = nil, liquidation_price: Double? = nil, unrealized_pnl: Double? = nil,
         margin_locked: Double? = nil, fee: Double? = nil, margin: Double? = nil) {
        self.id = UUID().uuidString
        self.date = date; self.value = value; self.cash = cash; self.action = action
        self.amount = amount; self.shares = shares; self.price = price
        self.dividend = dividend; self.expense = expense; self.cash_interest = cash_interest
        self.fund_size = fund_size; self.margin_available = margin_available
        self.margin_borrowed = margin_borrowed; self.margin_expense = margin_expense
        self.notes = notes; self.contracts = contracts; self.entry_price = entry_price
        self.liquidation_price = liquidation_price; self.unrealized_pnl = unrealized_pnl
        self.margin_locked = margin_locked; self.fee = fee; self.margin = margin
    }
}

// Computed summary for a fund — eliminates repeated computation across views
struct FundSummary {
    let fund: FundData
    let state: FundState
    let recommendation: Recommendation?
    let metrics: FundMetrics
    let isCash: Bool
    let features: FundTypeFeatures
    let closedMetrics: ClosedFundMetrics?

    // Effective values — prefer closedMetrics for closed funds, fall back to state/metrics
    var effectiveInvested: Double { closedMetrics?.totalInvestedUsd ?? state.startInputUsd }
    var effectiveRealized: Double { closedMetrics?.netGainUsd ?? state.realizedGainsUsd }
    var effectiveRealizedAPY: Double { closedMetrics?.apy ?? realizedAPY }
    var effectiveLiquidAPY: Double { closedMetrics?.apy ?? liquidAPY }

    // Convenience accessors from metrics
    var currentValue: Double { metrics.currentValue }
    var startDate: String { getFundStartDate(fund.entries) }
    var daysActive: Int { metrics.daysActive }
    var twfs: Double { metrics.timeWeightedFundSize }
    var realizedAPY: Double { metrics.realizedAPY }
    var liquidGain: Double { metrics.unrealizedGains + metrics.realizedGains }
    var liquidAPY: Double { metrics.liquidAPY }
    var unrealizedGains: Double { metrics.unrealizedGains }
    var projectedAnnualReturn: Double { metrics.projectedAnnualReturn }
    var fundSharesPct: Double { metrics.fundSharesPct }

    init(_ fund: FundData, asOfDate: String? = nil) {
        let today = asOfDate ?? todayString()

        self.fund = fund
        self.isCash = EscapeMint.isCashFund(fund.config.fund_type)
        self.features = getFeatures(fund.config.fund_type)

        // Single computation — returns both metrics and state
        let result = computeFundMetricsForFund(fund, asOfDate: today)
        self.metrics = result.metrics
        self.state = result.state
        self.recommendation = computeRecommendation(config: fund.config, state: result.state)
        self.closedMetrics = Self.buildClosedMetrics(fund: fund, asOfDate: today)
    }

    init(_ fund: FundData, metrics: FundMetrics, state: FundState) {
        self.fund = fund
        self.isCash = EscapeMint.isCashFund(fund.config.fund_type)
        self.features = getFeatures(fund.config.fund_type)
        self.metrics = metrics
        self.state = state
        self.recommendation = computeRecommendation(config: fund.config, state: state)
        self.closedMetrics = Self.buildClosedMetrics(fund: fund, asOfDate: todayString())
    }

    private static func buildClosedMetrics(fund: FundData, asOfDate: String) -> ClosedFundMetrics? {
        guard fund.config.status == .closed else { return nil }
        let trades = entriesToTrades(fund.entries)
        let dividends = entriesToDividends(fund.entries)
        let expenses = entriesToExpenses(fund.entries)
        let cashflows = entriesToCashFlows(fund.entries)
        let ci = fund.config.manage_cash == true
            ? computeCashInterest(config: fund.config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
            : 0
        let startDate = getFundStartDate(fund.entries)
        let endDate = fund.entries.last?.date ?? asOfDate
        return computeClosedFundMetrics(trades: trades, dividends: dividends, expenses: expenses, cashInterest: ci, startDate: startDate, endDate: endDate)
    }
}

struct FundData: Identifiable {
    var id: String { "\(platform)-\(ticker)" }
    var platform: String
    var ticker: String
    var config: FundConfig
    var entries: [FundEntry]
}

// Engine input types
struct Trade {
    let date: String
    let amountUsd: Double
    let type: TradeType
    var shares: Double?
    var value: Double?

    enum TradeType: String {
        case buy, sell
    }
}

struct CashFlow {
    let date: String
    let amountUsd: Double
    let type: CashFlowType

    enum CashFlowType: String {
        case deposit, withdrawal
    }
}

struct Dividend {
    let date: String
    let amountUsd: Double
}

struct Expense {
    let date: String
    let amountUsd: Double
}

struct FundState {
    var cashAvailableUsd: Double = 0
    var expectedTargetUsd: Double = 0
    var actualValueUsd: Double = 0
    var startInputUsd: Double = 0
    var gainUsd: Double = 0
    var gainPct: Double = 0
    var targetDiffUsd: Double = 0
    var cashInterestUsd: Double = 0
    var realizedGainsUsd: Double = 0
}

struct Recommendation {
    let action: FundAction
    let amount: Double
    let reasoning: String
}

// Full per-fund metrics (matches web app's FundMetrics)
struct FundMetrics {
    let id: String
    let platform: String
    let ticker: String
    let status: FundStatus
    let fundType: FundType
    let category: FundCategory?
    let fundSize: Double
    let currentValue: Double
    let startInput: Double
    let daysActive: Int
    let timeWeightedFundSize: Double
    let realizedGains: Double
    let unrealizedGains: Double
    let realizedAPY: Double
    let liquidAPY: Double
    let projectedAnnualReturn: Double
    let gainUsd: Double
    let gainPct: Double
    let totalDividends: Double
    let totalExpenses: Double
    let totalCashInterest: Double
    var fundShares: Double = 0
    var fundSharesPct: Double = 0
}

// Historical performance metrics for closed funds
struct ClosedFundMetrics {
    let totalInvestedUsd: Double
    let totalReturnedUsd: Double
    let totalDividendsUsd: Double
    let totalCashInterestUsd: Double
    let totalExpensesUsd: Double
    let netGainUsd: Double
    let returnPct: Double
    let apy: Double
    let startDate: String
    let endDate: String
    let durationDays: Int
}

// Portfolio-level aggregate (matches web app's AggregateMetrics)
struct PortfolioMetrics {
    var totalFundSize: Double = 0
    var totalValue: Double = 0
    var totalStartInput: Double = 0
    var totalTimeWeightedFundSize: Double = 0
    var totalDaysActive: Int = 0
    var totalRealizedGains: Double = 0
    var totalUnrealizedGains: Double = 0
    var realizedAPY: Double = 0
    var liquidAPY: Double = 0
    var projectedAnnualReturn: Double = 0
    var totalGainUsd: Double = 0
    var totalGainPct: Double = 0
    var activeFunds: Int = 0
    var closedFunds: Int = 0
    var portfolioDays: Int = 0
    var cashBalance: Double = 0
    var totalInterest: Double = 0
    var funds: [FundMetrics] = []
    var states: [FundState] = []
}
