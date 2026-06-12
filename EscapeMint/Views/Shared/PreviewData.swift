#if DEBUG
import SwiftUI

/// Sample fixtures used exclusively by `#Preview` macros. Compiled only in DEBUG
/// builds so none of this ships in Release. Mirrors the shapes the real engine
/// produces (`FundData` → `FundSummary` → `PortfolioMetrics`) so previews render
/// with realistic numbers, recommendations, and chart series.
enum PreviewData {

    // MARK: - Sample funds

    /// An active stock fund with a few months of weekly DCA history.
    static var stockFund: FundData {
        var config = fundTypeDefaults[.stock]!
        config.platform = "robinhood"
        config.ticker = "VOO"
        config.category = .volatility
        return FundData(
            platform: "robinhood",
            ticker: "VOO",
            config: config,
            entries: [
                FundEntry(date: "2025-01-06", value: 500, cash: 4500, action: .BUY, amount: 500, shares: 1.1, price: 454),
                FundEntry(date: "2025-01-13", value: 1010, cash: 4350, action: .BUY, amount: 150, shares: 0.33, price: 458),
                FundEntry(date: "2025-01-20", value: 1180, cash: 4200, action: .BUY, amount: 150, shares: 0.32, price: 462),
                FundEntry(date: "2025-02-03", value: 1240, cash: 4200, action: .HOLD),
                FundEntry(date: "2025-02-17", value: 1390, cash: 4050, action: .BUY, amount: 150, shares: 0.31, price: 471),
                FundEntry(date: "2025-03-03", value: 1320, cash: 4050, action: .HOLD),
                FundEntry(date: "2025-03-17", value: 1510, cash: 3850, action: .BUY, amount: 200, shares: 0.42, price: 476),
            ]
        )
    }

    /// An active crypto fund — higher volatility, with dividends/staking left empty.
    static var cryptoFund: FundData {
        var config = fundTypeDefaults[.crypto]!
        config.platform = "coinbase"
        config.ticker = "BTC"
        config.category = .sov
        return FundData(
            platform: "coinbase",
            ticker: "BTC",
            config: config,
            entries: [
                FundEntry(date: "2025-01-06", value: 200, cash: 1800, action: .BUY, amount: 200, shares: 0.002, price: 95000),
                FundEntry(date: "2025-01-20", value: 430, cash: 1650, action: .BUY, amount: 150, shares: 0.0015, price: 98000),
                FundEntry(date: "2025-02-10", value: 380, cash: 1650, action: .HOLD),
                FundEntry(date: "2025-03-03", value: 560, cash: 1450, action: .BUY, amount: 200, shares: 0.0019, price: 102000),
                FundEntry(date: "2025-03-24", value: 720, cash: 1450, action: .HOLD),
            ]
        )
    }

    /// A cash fund accruing interest — drives the cash-fund branch in card/detail views.
    static var cashFund: FundData {
        var config = fundTypeDefaults[.cash]!
        config.platform = "robinhood"
        config.ticker = "CASH"
        config.category = .liquidity
        return FundData(
            platform: "robinhood",
            ticker: "CASH",
            config: config,
            entries: [
                FundEntry(date: "2025-01-01", value: 10000, action: .DEPOSIT, amount: 10000),
                FundEntry(date: "2025-02-01", value: 10034, action: .HOLD, cash_interest: 34),
                FundEntry(date: "2025-03-01", value: 10068, action: .HOLD, cash_interest: 34),
            ]
        )
    }

    /// A closed (fully liquidated) fund — exercises the closed-metrics branches.
    static var closedFund: FundData {
        var config = fundTypeDefaults[.stock]!
        config.platform = "robinhood"
        config.ticker = "NVDA"
        config.category = .volatility
        config.status = .closed
        return FundData(
            platform: "robinhood",
            ticker: "NVDA",
            config: config,
            entries: [
                FundEntry(date: "2024-09-01", value: 1000, cash: 0, action: .BUY, amount: 1000, shares: 9, price: 111),
                FundEntry(date: "2024-11-01", value: 1350, cash: 0, action: .HOLD),
                FundEntry(date: "2025-01-15", value: 1480, cash: 1480, action: .SELL, amount: 1480, shares: 9, price: 164),
            ]
        )
    }

    /// All sample funds together.
    static var allFunds: [FundData] { [stockFund, cryptoFund, cashFund, closedFund] }

    // MARK: - Derived fixtures

    static func summary(_ fund: FundData) -> FundSummary {
        FundSummary(fund, asOfDate: "2025-04-01")
    }

    static var stockSummary: FundSummary { summary(stockFund) }
    static var cashSummary: FundSummary { summary(cashFund) }
    static var closedSummary: FundSummary { summary(closedFund) }

    // MARK: - Store seeding

    /// Seed the shared store with sample funds so top-level views (which read
    /// `FundDataStore.shared`) render populated content in previews. Returns the
    /// store so callers can use it as `.task`-free preview content.
    @MainActor
    @discardableResult
    static func seedStore() -> FundDataStore {
        FundDataStore.shared.seedForPreview(allFunds, asOfDate: "2025-04-01")
        return FundDataStore.shared
    }
}
#endif
