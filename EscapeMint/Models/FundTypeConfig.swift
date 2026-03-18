import SwiftUI

struct FundTypeFeatures {
    let allowsTrading: Bool
    let allowsRecommendations: Bool
    let supportsDividends: Bool
    let supportsCashInterest: Bool
    let supportsShares: Bool
    let supportsMargin: Bool
    let label: String
    let color: Color
}

let fundTypeFeatures: [FundType: FundTypeFeatures] = [
    .cash: FundTypeFeatures(
        allowsTrading: false, allowsRecommendations: false,
        supportsDividends: false, supportsCashInterest: true,
        supportsShares: false, supportsMargin: true,
        label: "Cash", color: .blue
    ),
    .stock: FundTypeFeatures(
        allowsTrading: true, allowsRecommendations: true,
        supportsDividends: true, supportsCashInterest: true,
        supportsShares: true, supportsMargin: true,
        label: "Stock", color: .green
    ),
    .crypto: FundTypeFeatures(
        allowsTrading: true, allowsRecommendations: true,
        supportsDividends: false, supportsCashInterest: true,
        supportsShares: true, supportsMargin: false,
        label: "Crypto", color: .yellow
    ),
    .derivatives: FundTypeFeatures(
        allowsTrading: true, allowsRecommendations: false,
        supportsDividends: false, supportsCashInterest: true,
        supportsShares: false, supportsMargin: true,
        label: "Futures", color: .orange
    ),
]

let fundTypeDefaults: [FundType: FundConfig] = [
    .cash: FundConfig(
        fund_type: .cash, status: .active,
        target_apy: 0, interval_days: 1,
        input_min_usd: 0, input_mid_usd: 0, input_max_usd: 0,
        max_at_pct: 0, min_profit_usd: 0, cash_apy: 0.04,
        manage_cash: true, accumulate: true
    ),
    .stock: FundConfig(
        fund_type: .stock, status: .active,
        target_apy: 0.10, interval_days: 7,
        input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
        max_at_pct: -0.25, min_profit_usd: 100, cash_apy: 0.044,
        manage_cash: true, accumulate: true
    ),
    .crypto: FundConfig(
        fund_type: .crypto, status: .active,
        target_apy: 0.15, interval_days: 7,
        input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
        max_at_pct: -0.30, min_profit_usd: 100, cash_apy: 0.05,
        manage_cash: true, accumulate: true
    ),
    .derivatives: FundConfig(
        fund_type: .derivatives, status: .active,
        target_apy: 0, interval_days: 1,
        input_min_usd: 0, input_mid_usd: 0, input_max_usd: 0,
        max_at_pct: 0, min_profit_usd: 0, cash_apy: 0.05,
        manage_cash: true, margin_enabled: true, accumulate: false
    ),
]

let allowedActions: [FundType: [FundAction]] = [
    .cash: [.DEPOSIT, .WITHDRAW, .HOLD, .MARGIN],
    .stock: [.BUY, .SELL, .HOLD, .DEPOSIT, .WITHDRAW],
    .crypto: [.BUY, .SELL, .HOLD, .DEPOSIT, .WITHDRAW],
    .derivatives: [.BUY, .SELL, .FUNDING, .INTEREST, .REBATE, .FEE, .DEPOSIT, .WITHDRAW],
]

let categoryConfig: [FundCategory: (label: String, shortLabel: String, color: Color)] = [
    .liquidity: ("Liquidity", "Liq", .blue),
    .yield: ("Yield", "Yld", .green),
    .sov: ("Store of Value", "SoV", .yellow),
    .volatility: ("Volatility", "Vol", .red),
]

func isCashFund(_ type: FundType?) -> Bool {
    type == .cash
}

func getFeatures(_ type: FundType?) -> FundTypeFeatures {
    fundTypeFeatures[type ?? .stock] ?? FundTypeFeatures(
        allowsTrading: true, allowsRecommendations: true,
        supportsDividends: true, supportsCashInterest: true,
        supportsShares: true, supportsMargin: false,
        label: "Unknown", color: .gray
    )
}
