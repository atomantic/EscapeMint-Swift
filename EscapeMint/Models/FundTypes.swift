import Foundation

enum FundType: String, Codable, CaseIterable {
    case cash
    case stock
    case crypto
    case derivatives
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
    var margin_apr: Double?
    var margin_access_usd: Double?
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

    enum CodingKeys: String, CodingKey {
        case platform = "__platform"
        case ticker = "__ticker"
        case fund_type, status, category
        case fund_size_usd, target_apy, interval_days
        case input_min_usd, input_mid_usd, input_max_usd
        case max_at_pct, min_profit_usd
        case cash_apy, manage_cash
        case margin_apr, margin_access_usd, margin_enabled
        case accumulate, dividend_reinvest, interest_reinvest, expense_from_fund
        case initial_margin_rate, maintenance_margin_rate, contract_multiplier
    }
}

struct FundEntry: Codable, Identifiable {
    var id: String { "\(date)-\(UUID().uuidString.prefix(4))" }
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
