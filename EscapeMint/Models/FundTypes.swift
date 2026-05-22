import Foundation
import CryptoKit

enum FundType: String, Codable, CaseIterable {
    case cash
    case stock
    case crypto
    case derivatives

    /// Fund types available for user creation (derivatives is hidden/internal)
    static let creatableCases = allCases.filter { $0 != .derivatives }

    /// Stock and crypto funds that support DCA trading configuration
    var isTradingType: Bool { self == .stock || self == .crypto }
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

enum EquityInputMethod: String, Codable, CaseIterable {
    case direct
    case shares_price
}

struct FundConfig: Codable {
    // Metadata (prefixed with __ in JSON)
    var fund_id: String?
    var platform: String?
    var ticker: String?

    // Core
    var fund_type: FundType?
    var status: FundStatus?
    var category: FundCategory?
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
    var cash_fund: String?

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

    // Display
    var dollar_decimals: Int?

    // Guided-entry behavior
    var equity_input: EquityInputMethod?

    // Chart bounds (persisted per-fund)
    var chart_bounds: [String: ChartBounds]?
    // Cached expensive history computations to avoid repeated redraw recalculation.
    var history_cache: FundHistoryCache?

    enum CodingKeys: String, CodingKey {
        case fund_id = "__fund_id"
        case platform = "__platform"
        case ticker = "__ticker"
        case fund_type, status, category
        case target_apy, interval_days
        case input_min_usd, input_mid_usd, input_max_usd
        case max_at_pct, min_profit_usd
        case cash_apy, manage_cash, cash_fund
        case margin_enabled
        case accumulate, dividend_reinvest, interest_reinvest, expense_from_fund
        case initial_margin_rate, maintenance_margin_rate, contract_multiplier
        case dollar_decimals
        case equity_input
        case chart_bounds
        case history_cache
    }
}

struct FundHistoryCache: Codable {
    var entryFingerprint: String
    var closedMetrics: ClosedFundMetrics?
}

extension FundConfig {
    /// Effective dollar decimal places (defaults to 2)
    var dollarDec: Int { dollar_decimals ?? 2 }

    /// Effective equity-input method for the guided entry wizard.
    /// Defaults to `.direct` for all fund types — the common case is a user who can
    /// see the fund's current dollar value on their trading platform. `.shares_price`
    /// is an advanced opt-in for platforms (e.g. Crypto.com) where equity isn't
    /// directly observable and the user reasons in shares + price instead.
    var effectiveEquityInput: EquityInputMethod {
        equity_input ?? .direct
    }
}

struct ChartBounds: Codable, Equatable {
    var yMin: Double?
    var yMax: Double?

    var isEmpty: Bool { yMin == nil && yMax == nil }
}

struct FundEntry: Identifiable {
    /// Deterministic identity derived from the entry's content so ForEach can diff stable rows
    /// across reloads (iCloud sync, progressive load). Previously `UUID().uuidString`, which
    /// changed on every deserialization and forced SwiftUI to tear down every visible row.
    ///
    /// The composite includes date + value + action + amount + shares + cash. In practice this
    /// is effectively unique across real user data — two entries with identical values of
    /// ALL these fields are either true duplicates (same deposit made twice on the same day)
    /// or a data-entry mistake, and can safely collide on ID. This is computed, not stored —
    /// equal content always yields equal IDs, so Identifiable semantics are preserved across
    /// reloads.
    var id: String {
        let a = action?.rawValue ?? ""
        return "\(date)|\(value)|\(a)|\(amount ?? 0)|\(shares ?? 0)|\(cash ?? 0)"
    }
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
    /// Fingerprint computed during `buildClosedMetrics`. Cached on the summary so the
    /// persistence path (`persistHistoryCachesIfNeeded`) can compare without re-hashing the
    /// entry history a second time per recompute. `nil` for non-closed funds.
    let closedHistoryFingerprint: String?

    // Effective values — prefer closedMetrics for closed funds, fall back to state/metrics
    var effectiveInvested: Double { closedMetrics?.totalInvestedUsd ?? state.startInputUsd }
    var effectiveRealized: Double { closedMetrics?.netGainUsd ?? state.realizedGainsUsd }
    var effectiveRealizedAPY: Double { closedMetrics?.apy ?? realizedAPY }
    var effectiveLiquidAPY: Double { closedMetrics?.apy ?? liquidAPY }

    /// Whether this fund is due for its next DCA action (interval elapsed since last entry)
    let isDueForAction: Bool

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

    init(_ fund: FundData, asOfDate: String? = nil, allFunds: [FundData]? = nil) {
        let today = asOfDate ?? todayString()

        self.fund = fund
        self.isCash = EscapeMint.isCashFund(fund.config.fund_type)
        self.features = getFeatures(fund.config.fund_type)

        // Single computation — returns both metrics and state
        let result = computeFundMetricsForFund(fund, asOfDate: today)
        self.metrics = result.metrics

        // Resolve cash from platform cash fund for manage_cash=false funds
        var state = result.state
        if fund.config.manage_cash == false, let allFunds {
            let cashFundId = resolveCashFundId(config: fund.config, platform: fund.platform)
            if let cashFund = allFunds.first(where: { $0.id == cashFundId }),
               let latest = cashFund.entries.max(by: { $0.date < $1.date }) {
                state.cashAvailableUsd = latest.cash ?? latest.value
            } else {
                state.cashAvailableUsd = 0
            }
        }

        self.state = state
        self.recommendation = Self.computeMarginAwareRecommendation(fund: fund, state: state)
        let closed = Self.buildClosedMetrics(fund: fund, asOfDate: today)
        self.closedMetrics = closed.metrics
        self.closedHistoryFingerprint = closed.fingerprint
        self.isDueForAction = Self.computeIsDueForAction(fund: fund, today: today)
    }

    init(_ fund: FundData, metrics: FundMetrics, state: FundState) {
        self.fund = fund
        self.isCash = EscapeMint.isCashFund(fund.config.fund_type)
        self.features = getFeatures(fund.config.fund_type)
        self.metrics = metrics
        self.state = state
        self.recommendation = Self.computeMarginAwareRecommendation(fund: fund, state: state)
        let today = todayString()
        let closed = Self.buildClosedMetrics(fund: fund, asOfDate: today)
        self.closedMetrics = closed.metrics
        self.closedHistoryFingerprint = closed.fingerprint
        self.isDueForAction = Self.computeIsDueForAction(fund: fund, today: today)
    }

    /// Computes recommendation with margin_available added to cash when margin is enabled
    private static func computeMarginAwareRecommendation(fund: FundData, state: FundState) -> Recommendation? {
        var stateForRec = state
        if fund.config.margin_enabled == true,
           let latestEntry = fund.entries.last,
           let marginAvail = latestEntry.margin_available, marginAvail > 0 {
            stateForRec.cashAvailableUsd += marginAvail
        }
        return computeRecommendation(config: fund.config, state: stateForRec)
    }

    private static func computeIsDueForAction(fund: FundData, today: String) -> Bool {
        // Stock funds: not actionable on weekends/holidays
        if fund.config.fund_type == .stock && !isStockTradingDay(today) { return false }
        guard let intervalDays = fund.config.interval_days, intervalDays > 0 else { return true }
        guard let lastEntry = fund.entries.last else { return true }
        return daysBetween(lastEntry.date, today) >= intervalDays
    }

    /// Returns the closed-fund metrics AND the fingerprint used to gate the cache, so callers
    /// (the persistence path) can reuse the fingerprint without re-hashing the entry history.
    /// Both are `nil` for non-closed funds.
    private static func buildClosedMetrics(fund: FundData, asOfDate: String) -> (metrics: ClosedFundMetrics?, fingerprint: String?) {
        guard fund.config.status == .closed else { return (nil, nil) }
        let fingerprint = historyFingerprint(for: fund)
        if let cache = fund.config.history_cache,
           cache.entryFingerprint == fingerprint,
           let cached = cache.closedMetrics {
            return (cached, fingerprint)
        }
        let trades = entriesToTrades(fund.entries)
        let dividends = entriesToDividends(fund.entries)
        let expenses = entriesToExpenses(fund.entries)
        let cashflows = entriesToCashFlows(fund.entries)
        let ci = fund.config.manage_cash == true
            ? computeCashInterest(config: fund.config, trades: trades, cashflows: cashflows, asOfDate: asOfDate)
            : 0
        let startDate = getFundStartDate(fund.entries)
        let endDate = fund.entries.last?.date ?? asOfDate
        let metrics = computeClosedFundMetrics(trades: trades, dividends: dividends, expenses: expenses, cashInterest: ci, startDate: startDate, endDate: endDate)
        return (metrics, fingerprint)
    }

    /// Deterministic fingerprint for the inputs to `computeClosedFundMetrics` / `computeCashInterest`.
    /// MUST be stable across process restarts (Swift's `Hasher` is not — it's seeded per-process,
    /// which would invalidate every persisted cache on next launch).
    /// MUST include every config field that those compute functions read — if you add a new
    /// metrics-affecting field to `FundConfig` (or change what the compute path reads), update
    /// this list or the cache will return stale results.
    /// Optionals are encoded with explicit `S`/`N` tags so a real value (e.g. `amount == -1`)
    /// can't collide with absence. Bytes are streamed into SHA256 incrementally to avoid
    /// allocating a large intermediate payload string.
    static func historyFingerprint(for fund: FundData) -> String {
        var hasher = SHA256()
        func feed(_ s: String) { hasher.update(data: Data(s.utf8)) }
        func optD(_ d: Double?) -> String { d.map { "S\($0)" } ?? "N" }
        func optS(_ s: String?) -> String { s.map { "S\($0)" } ?? "N" }
        feed("status:\(fund.config.status?.rawValue ?? "")\n")
        feed("manage_cash:\(fund.config.manage_cash == true)\n")
        feed("cash_apy:\(fund.config.cash_apy ?? 0)\n")
        feed("dividend_reinvest:\(fund.config.dividend_reinvest == true)\n")
        feed("interest_reinvest:\(fund.config.interest_reinvest == true)\n")
        feed("expense_from_fund:\(fund.config.expense_from_fund == true)\n")
        feed("count:\(fund.entries.count)\n")
        for e in fund.entries {
            feed("\(e.date)|\(e.value)|\(optD(e.cash))|\(optS(e.action?.rawValue))|\(optD(e.amount))|\(optD(e.shares))|\(optD(e.dividend))|\(optD(e.expense))|\(optD(e.cash_interest))|\(optD(e.fund_size))\n")
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct FundData: Identifiable {
    var id: String {
        if let persistedId = config.fund_id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persistedId.isEmpty {
            return persistedId
        }
        return "\(platform)-\(ticker)"
    }
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
struct ClosedFundMetrics: Codable {
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
