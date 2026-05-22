import XCTest
@testable import EscapeMint

/// Tests for fund metrics computation: derivatives, cash funds, portfolio aggregates,
/// entry rows, realized gains, cash interest, and edge cases.
final class FundMetricsTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(
        fundType: FundType = .stock,
        status: FundStatus = .active,
        targetApy: Double = 0.10,
        intervalDays: Int = 7,
        inputMin: Double = 100,
        inputMid: Double = 150,
        inputMax: Double = 200,
        maxAtPct: Double = -0.25,
        minProfit: Double = 100,
        cashApy: Double = 0.044,
        manageCash: Bool = true,
        accumulate: Bool = true
    ) -> FundConfig {
        FundConfig(
            fund_type: fundType, status: status,
            target_apy: targetApy, interval_days: intervalDays,
            input_min_usd: inputMin, input_mid_usd: inputMid, input_max_usd: inputMax,
            max_at_pct: maxAtPct, min_profit_usd: minProfit,
            cash_apy: cashApy, manage_cash: manageCash, accumulate: accumulate
        )
    }

    // MARK: - Derivatives Fund Metrics

    func testDerivativesFundMetricsBasic() {
        var config = FundConfig()
        config.fund_type = .derivatives
        config.status = .active

        let entries = [
            FundEntry(date: "2025-01-01", value: 0, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2025-01-02", value: 0, cash: 9900, action: .BUY, amount: 1000,
                      price: 1000, contracts: 1, fee: 1),
            FundEntry(date: "2025-01-10", value: 0, cash: 10100, action: .SELL, amount: 1200,
                      price: 1200, contracts: 1, fee: 1),
        ]

        let fund = FundData(platform: "test", ticker: "PERP", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2025-01-15")

        XCTAssertEqual(result.metrics.fundType, FundType.derivatives)
        XCTAssertEqual(result.metrics.platform, "test")
        XCTAssertEqual(result.metrics.ticker, "PERP")
        // Realized gain: sold 1200 - bought 1000 = 200
        XCTAssertEqual(result.metrics.realizedGains, 200, accuracy: 0.01)
        // Fees: 1 + 1 = 2
        XCTAssertEqual(result.metrics.totalExpenses, 2, accuracy: 0.01)
    }

    func testDerivativesFundMetricsFunding() {
        var config = FundConfig()
        config.fund_type = .derivatives
        config.status = .active

        let entries = [
            FundEntry(date: "2025-01-01", value: 0, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2025-01-02", value: 0, action: .BUY, amount: 1000,
                      price: 1000, contracts: 1, fee: 0.5),
            FundEntry(date: "2025-01-03", value: 0, action: .FUNDING, amount: 5),
            FundEntry(date: "2025-01-04", value: 0, action: .INTEREST, amount: 2),
            FundEntry(date: "2025-01-05", value: 0, action: .REBATE, amount: 1),
            FundEntry(date: "2025-01-06", value: 0, action: .FEE, amount: 3),
        ]

        let fund = FundData(platform: "test", ticker: "PERP", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2025-01-10")

        // Cash interest = INTEREST amount = 2
        XCTAssertEqual(result.metrics.totalCashInterest, 2, accuracy: 0.01)
        // Fees: BUY fee 0.5 + FEE action 3 = 3.5
        XCTAssertEqual(result.metrics.totalExpenses, 3.5, accuracy: 0.01)
    }

    func testDerivativesFundMetricsClosed() {
        var config = FundConfig()
        config.fund_type = .derivatives
        config.status = .closed

        let entries = [
            FundEntry(date: "2025-01-01", value: 0, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2025-01-02", value: 0, action: .BUY, amount: 1000, price: 1000, contracts: 1, fee: 0),
            FundEntry(date: "2025-01-10", value: 0, action: .SELL, amount: 1100, price: 1100, contracts: 1, fee: 0),
        ]

        let fund = FundData(platform: "test", ticker: "PERP", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2025-01-15")

        XCTAssertEqual(result.metrics.status, FundStatus.closed)
        XCTAssertEqual(result.metrics.fundSize, 0)
        XCTAssertEqual(result.metrics.currentValue, 0)
    }

    // MARK: - Cash Fund Metrics

    func testCashFundMetrics() {
        let config = makeConfig(fundType: .cash, cashApy: 0.04, manageCash: true)
        let entries = [
            FundEntry(date: "2024-01-01", value: 10000, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2024-07-01", value: 10200, cash: 10200, action: .HOLD, cash_interest: 200),
        ]

        let fund = FundData(platform: "test", ticker: "USD", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2025-01-01")

        XCTAssertEqual(result.metrics.fundType, .cash)
        XCTAssertEqual(result.metrics.currentValue, 10200, accuracy: 0.01)
        // The only cash_interest entry records exactly 200; totalCashInterest sums those entries
        XCTAssertEqual(result.metrics.totalCashInterest, 200, accuracy: 0.01)
    }

    func testCashPLChartUsesRecordedInterestNotProjectedAPY() {
        let config = makeConfig(fundType: .cash, cashApy: 0.50, manageCash: true)
        let entries = [
            FundEntry(date: "2026-01-01", value: 1000, cash: 1000, action: .DEPOSIT, amount: 1000),
            FundEntry(date: "2026-02-01", value: 1005, cash: 1005, action: .HOLD),
            FundEntry(date: "2026-03-01", value: 1012, cash: 1012, action: .HOLD, cash_interest: 7),
            FundEntry(date: "2026-04-01", value: 1010, cash: 1010, action: .HOLD, expense: 2),
        ]

        let points = computePLPoints(entries: entries, config: config)

        XCTAssertEqual(points.map(\.realized), [0, 0, 7, 5])
        XCTAssertEqual(points.map(\.liquid), [0, 0, 7, 5])
    }

    func testCashPLChartCoalescesSameDayEntriesToFinalDailyPoint() {
        let config = makeConfig(fundType: .cash, manageCash: true)
        let entries = [
            FundEntry(date: "2026-01-01", value: 1000, cash: 1000, action: .DEPOSIT, amount: 1000),
            FundEntry(date: "2026-01-01", value: 1004, cash: 1004, action: .HOLD, cash_interest: 4),
            FundEntry(date: "2026-02-01", value: 1006, cash: 1006, action: .HOLD, cash_interest: 2),
        ]

        let points = computePLPoints(entries: entries, config: config)

        XCTAssertEqual(points.map(\.date), ["2026-01-01", "2026-02-01"])
        XCTAssertEqual(points.map(\.realized), [4, 6])
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
    }

    func testCashFundFallbackToFundSize() {
        // When cash field is nil, engine should fall back to fund_size then value
        let config = makeConfig(fundType: .cash, cashApy: 0.04, manageCash: true, accumulate: true)
        let entries = [
            FundEntry(date: "2023-01-01", value: 0, action: .HOLD, amount: 100, fund_size: 100),
            FundEntry(date: "2023-06-01", value: 0, action: .HOLD, amount: 100, cash_interest: 50, fund_size: 245.55),
            // Latest entry: user updated equity and fund_size but cash field is nil
            FundEntry(date: "2026-03-26", value: 2012.41, action: .HOLD, amount: 100, fund_size: 2012.41),
        ]

        let fund = FundData(platform: "robinhood", ticker: "cash", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2026-03-26")

        XCTAssertEqual(result.metrics.currentValue, 2012.41, accuracy: 0.01, "currentValue should fall back to fund_size when cash is nil")
        XCTAssertEqual(result.state.startInputUsd, 2012.41, accuracy: 0.01, "startInput should equal cash balance for cash funds")
        XCTAssertEqual(result.state.cashAvailableUsd, 2012.41, accuracy: 0.01, "cashAvailable should equal cash balance for cash funds")
    }

    func testCashFundFallbackToValue() {
        // When both cash and fund_size are nil, engine should fall back to value
        let config = makeConfig(fundType: .cash, cashApy: 0.04, manageCash: true)
        let entries = [
            FundEntry(date: "2023-01-01", value: 5000, action: .HOLD, amount: 5000),
        ]

        let fund = FundData(platform: "test", ticker: "cash", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2025-01-01")

        XCTAssertEqual(result.metrics.currentValue, 5000, accuracy: 0.01, "currentValue should fall back to value when cash and fund_size are nil")
        XCTAssertEqual(result.state.startInputUsd, 5000, accuracy: 0.01)
        XCTAssertEqual(result.state.cashAvailableUsd, 5000, accuracy: 0.01)
    }

    func testCashFundExplicitZeroCashFallsThrough() {
        // Bug: cash field is explicitly 0 (not nil) — ?? doesn't fall through
        // Engine must treat 0 as "not set" and use fund_size/value instead
        let config = makeConfig(fundType: .cash, cashApy: 0.04, manageCash: true, accumulate: true)
        let entries = [
            // cash is explicitly 0.0, but fund_size and value are set
            FundEntry(date: "2026-03-26", value: 2012.41, cash: 0, action: .HOLD, amount: 100, fund_size: 2012.41),
        ]

        let fund = FundData(platform: "robinhood", ticker: "cash", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2026-03-26")

        XCTAssertEqual(result.metrics.currentValue, 2012.41, accuracy: 0.01, "Explicit cash=0 should fall through to fund_size")
        XCTAssertEqual(result.state.startInputUsd, 2012.41, accuracy: 0.01)
        XCTAssertEqual(result.state.cashAvailableUsd, 2012.41, accuracy: 0.01)
    }

    func testCashFundNoRecommendation() {
        let config = makeConfig(fundType: .cash)
        let state = FundState(cashAvailableUsd: 5000, actualValueUsd: 5000)
        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNil(rec)
    }

    // MARK: - Cash Interest Edge Cases

    func testCashInterestZeroApy() {
        let config = makeConfig(cashApy: 0)
        let trades = [Trade(date: "2025-01-01", amountUsd: 1000, type: .buy)]
        let cashflows = [CashFlow(date: "2024-12-31", amountUsd: 5000, type: .deposit)]
        let interest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: "2025-06-01")
        XCTAssertEqual(interest, 0)
    }

    func testCashInterestNoEvents() {
        let config = makeConfig(cashApy: 0.05)
        let interest = computeCashInterest(config: config, trades: [], cashflows: [], asOfDate: "2025-01-01")
        XCTAssertEqual(interest, 0)
    }

    func testCashInterestMultipleDeposits() {
        let config = makeConfig(cashApy: 0.04)
        let cashflows = [
            CashFlow(date: "2024-01-01", amountUsd: 5000, type: .deposit),
            CashFlow(date: "2024-07-01", amountUsd: 5000, type: .deposit),
        ]
        let interest = computeCashInterest(config: config, trades: [], cashflows: cashflows, asOfDate: "2025-01-01")
        // 5000 for 365d + 5000 for ~183d at 4%
        XCTAssertGreaterThan(interest, 200)
        XCTAssertLessThan(interest, 500)
    }

    func testCashInterestWithWithdrawal() {
        let config = makeConfig(cashApy: 0.04)
        let cashflows = [
            CashFlow(date: "2024-01-01", amountUsd: 10000, type: .deposit),
            CashFlow(date: "2024-07-01", amountUsd: 10000, type: .withdrawal),
        ]
        let interest = computeCashInterest(config: config, trades: [], cashflows: cashflows, asOfDate: "2025-01-01")
        // 10000 for ~182 days at 4%, then 0 cash for remaining ~183 days
        XCTAssertGreaterThan(interest, 0)
        XCTAssertLessThan(interest, 400)
    }

    // MARK: - Realized Gains

    func testRealizedGainsSimple() {
        let config = makeConfig()
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 1000, type: .buy),
            Trade(date: "2024-06-01", amountUsd: 1200, type: .sell),
        ]
        let cashflows = [CashFlow(date: "2024-01-01", amountUsd: 5000, type: .deposit)]
        let realized = computeRealizedGains(config: config, trades: trades, cashflows: cashflows, dividends: [], expenses: [], asOfDate: "2025-01-01")
        // Sell 1200 >= Buy 1000 -> realized = 200 + cash interest
        XCTAssertGreaterThanOrEqual(realized, 200)
    }

    func testRealizedGainsWithDividends() {
        let config = makeConfig()
        let trades = [Trade(date: "2024-01-01", amountUsd: 1000, type: .buy)]
        let dividends = [
            Dividend(date: "2024-04-01", amountUsd: 25),
            Dividend(date: "2024-07-01", amountUsd: 30),
        ]
        let cashflows = [CashFlow(date: "2024-01-01", amountUsd: 5000, type: .deposit)]
        let realized = computeRealizedGains(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: [], asOfDate: "2025-01-01")
        // Should include dividends: >= 55
        XCTAssertGreaterThanOrEqual(realized, 55)
    }

    func testRealizedGainsWithExpenses() {
        let config = makeConfig()
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 1000, type: .buy),
            Trade(date: "2024-06-01", amountUsd: 1200, type: .sell),
        ]
        let expenses = [Expense(date: "2024-03-01", amountUsd: 10)]
        let cashflows = [CashFlow(date: "2024-01-01", amountUsd: 5000, type: .deposit)]
        let realized = computeRealizedGains(config: config, trades: trades, cashflows: cashflows, dividends: [], expenses: expenses, asOfDate: "2025-01-01")
        // 200 gain - 10 expense + some cash interest
        XCTAssertGreaterThanOrEqual(realized, 190)
    }

    func testRealizedGainsNoTrades() {
        // cashApy: 0 so no interest accrues — realized gains must be exactly zero
        let config = makeConfig(cashApy: 0)
        let cashflows = [CashFlow(date: "2024-01-01", amountUsd: 5000, type: .deposit)]
        let realized = computeRealizedGains(config: config, trades: [], cashflows: cashflows, dividends: [], expenses: [], asOfDate: "2025-01-01")
        XCTAssertEqual(realized, 0, accuracy: 0.01)
    }

    // MARK: - Cash Available

    func testCashAvailableBasic() {
        let config = makeConfig(cashApy: 0)
        let trades = [Trade(date: "2025-01-01", amountUsd: 1000, type: .buy)]
        let cashflows = [CashFlow(date: "2024-12-31", amountUsd: 5000, type: .deposit)]
        let cash = computeCashAvailable(config: config, trades: trades, cashflows: cashflows, dividends: [], expenses: [], asOfDate: "2025-06-01")
        // 5000 deposit - 1000 buy = 4000
        XCTAssertEqual(cash, 4000, accuracy: 1.0)
    }

    func testCashAvailableWithDividendReinvest() {
        var config = makeConfig(cashApy: 0)
        config.dividend_reinvest = true
        let trades = [Trade(date: "2025-01-01", amountUsd: 1000, type: .buy)]
        let cashflows = [CashFlow(date: "2024-12-31", amountUsd: 5000, type: .deposit)]
        let dividends = [Dividend(date: "2025-03-01", amountUsd: 50)]
        let cash = computeCashAvailable(config: config, trades: trades, cashflows: cashflows, dividends: dividends, expenses: [], asOfDate: "2025-06-01")
        // 5000 - 1000 + 50 = 4050
        XCTAssertEqual(cash, 4050, accuracy: 1.0)
    }

    func testCashAvailableNoNegative() {
        let config = makeConfig(cashApy: 0)
        let trades = [Trade(date: "2025-01-01", amountUsd: 6000, type: .buy)]
        let cashflows = [CashFlow(date: "2024-12-31", amountUsd: 5000, type: .deposit)]
        let cash = computeCashAvailable(config: config, trades: trades, cashflows: cashflows, dividends: [], expenses: [], asOfDate: "2025-06-01")
        // Would be -1000 but capped at 0
        XCTAssertEqual(cash, 0, accuracy: 0.01)
    }

    // MARK: - Entry Rows

    func testComputeEntryRowsBasic() {
        let config = makeConfig(accumulate: true)
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20),
            FundEntry(date: "2024-04-01", value: 1100, action: .HOLD, dividend: 25),
            FundEntry(date: "2024-07-01", value: 1200, action: .HOLD),
        ]

        let rows = computeEntryRows(entries: entries, config: config)
        XCTAssertEqual(rows.count, 3)

        // First entry: just bought
        XCTAssertEqual(rows[0].invested, 1000, accuracy: 0.01)
        XCTAssertEqual(rows[0].extracted, 0, accuracy: 0.01)
        XCTAssertFalse(rows[0].isClosingEntry)

        // Dividend entry
        XCTAssertEqual(rows[1].sumDividends, 25, accuracy: 0.01)

        // Third entry: 200 unrealized + 25 realized dividends = 225 liquid
        XCTAssertEqual(rows[2].unrealized, 200, accuracy: 0.01)
    }

    func testComputeEntryRowsFullLiquidation() {
        let config = makeConfig(accumulate: true)
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20),
            FundEntry(date: "2024-06-01", value: 500, action: .SELL, amount: 500, shares: 20),
        ]

        let rows = computeEntryRows(entries: entries, config: config)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].isClosingEntry)
    }

    func testComputeEntryRowsDerivatives() {
        var config = FundConfig()
        config.fund_type = .derivatives
        let entries = [
            FundEntry(date: "2025-01-01", value: 0, cash: 10000, action: .DEPOSIT, amount: 10000),
            FundEntry(date: "2025-01-02", value: 0, action: .BUY, amount: 1000, price: 1000, contracts: 1, fee: 1),
            FundEntry(date: "2025-01-10", value: 0, action: .SELL, amount: 1200, price: 1200, contracts: 1, fee: 1),
        ]

        let rows = computeEntryRows(entries: entries, config: config)
        XCTAssertEqual(rows.count, 3)
        // After sell: realized = 1200 - 1000 = 200
        XCTAssertEqual(rows[2].realized, 200, accuracy: 0.01)
    }

    // MARK: - Portfolio Metrics

    func testPortfolioMetricsMultipleFunds() {
        let config1 = makeConfig()
        let entries1 = [
            FundEntry(date: "2024-06-01", value: 1000, action: .BUY, amount: 1000, shares: 20, fund_size: 5000),
            FundEntry(date: "2025-01-01", value: 1200, action: .HOLD, fund_size: 5000),
        ]
        let fund1 = FundData(platform: "test", ticker: "AAPL", config: config1, entries: entries1)

        let config2 = makeConfig(fundType: .crypto, targetApy: 0.15)
        let entries2 = [
            FundEntry(date: "2024-06-01", value: 500, action: .BUY, amount: 500, shares: 0.01, fund_size: 3000),
            FundEntry(date: "2025-01-01", value: 700, action: .HOLD, fund_size: 3000),
        ]
        let fund2 = FundData(platform: "test", ticker: "BTC", config: config2, entries: entries2)

        let cashConfig = makeConfig(fundType: .cash)
        let cashEntries = [
            FundEntry(date: "2024-01-01", value: 5000, cash: 5000, action: .DEPOSIT, amount: 5000),
        ]
        let cashFund = FundData(platform: "test", ticker: "cash", config: cashConfig, entries: cashEntries)

        let portfolio = computePortfolioMetrics([fund1, fund2, cashFund], asOfDate: "2025-01-01")

        XCTAssertEqual(portfolio.activeFunds, 3)
        XCTAssertEqual(portfolio.closedFunds, 0)
        XCTAssertEqual(portfolio.funds.count, 3)
        XCTAssertEqual(portfolio.states.count, 3)
        // fund1.currentValue=1200, fund2.currentValue=700, cashFund.currentValue=5000
        XCTAssertEqual(portfolio.totalValue, 6900, accuracy: 0.01)
        // fund1.fundSize=5000 (fund_size field), fund2.fundSize=3000, cashFund.fundSize=5000 (cash value)
        XCTAssertEqual(portfolio.totalFundSize, 13000, accuracy: 0.01)
        // Cash balance should include the cash fund
        XCTAssertEqual(portfolio.cashBalance, 5000, accuracy: 0.01)
    }

    func testPortfolioMetricsWithClosedFund() {
        let config = makeConfig(status: .closed)
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000),
            FundEntry(date: "2024-06-01", value: 1200, action: .SELL, amount: 1200),
        ]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let portfolio = computePortfolioMetrics([fund], asOfDate: "2025-01-01")
        XCTAssertEqual(portfolio.activeFunds, 0)
        XCTAssertEqual(portfolio.closedFunds, 1)
    }

    func testPortfolioMetricsEmpty() {
        let portfolio = computePortfolioMetrics([], asOfDate: "2025-01-01")
        XCTAssertEqual(portfolio.activeFunds, 0)
        XCTAssertEqual(portfolio.closedFunds, 0)
        XCTAssertEqual(portfolio.totalValue, 0)
        XCTAssertEqual(portfolio.funds.count, 0)
    }

    func testPortfolioMetricsFundShares() {
        let config = makeConfig()
        let entries1 = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20, fund_size: 5000),
            FundEntry(date: "2025-01-01", value: 1200, action: .HOLD, fund_size: 5000),
        ]
        let fund1 = FundData(platform: "test", ticker: "A", config: config, entries: entries1)

        let entries2 = [
            FundEntry(date: "2024-01-01", value: 2000, action: .BUY, amount: 2000, shares: 40, fund_size: 8000),
            FundEntry(date: "2025-01-01", value: 2400, action: .HOLD, fund_size: 8000),
        ]
        let fund2 = FundData(platform: "test", ticker: "B", config: config, entries: entries2)

        let portfolio = computePortfolioMetrics([fund1, fund2], asOfDate: "2025-01-01")

        // Both funds should have fund share percentages that sum to ~1.0
        let totalPct = portfolio.funds.reduce(0.0) { $0 + $1.fundSharesPct }
        XCTAssertEqual(totalPct, 1.0, accuracy: 0.01)
    }

    // MARK: - resolveCashFundId

    func testResolveCashFundIdDefault() {
        let config = FundConfig()
        XCTAssertEqual(resolveCashFundId(config: config, platform: "coinbase"), "coinbase-cash")
    }

    func testResolveCashFundIdCustom() {
        var config = FundConfig()
        config.cash_fund = "robinhood-savings"
        XCTAssertEqual(resolveCashFundId(config: config, platform: "coinbase"), "robinhood-savings")
    }

    // MARK: - Manage Cash = false

    func testManageCashFalseResolution() {
        var config = makeConfig(manageCash: false)
        config.manage_cash = false

        let entries = [
            FundEntry(date: "2024-06-01", value: 1000, action: .BUY, amount: 1000, shares: 20),
            FundEntry(date: "2025-01-01", value: 1200, action: .HOLD),
        ]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let cashConfig = makeConfig(fundType: .cash)
        let cashEntries = [
            FundEntry(date: "2024-01-01", value: 5000, cash: 5000, action: .DEPOSIT, amount: 5000),
        ]
        let cashFund = FundData(platform: "test", ticker: "cash", config: cashConfig, entries: cashEntries)

        let portfolio = computePortfolioMetrics([fund, cashFund], asOfDate: "2025-01-01")

        // The fund with manage_cash=false should resolve cash from the cash fund
        let fundState = portfolio.states[0]
        XCTAssertEqual(fundState.cashAvailableUsd, 5000, accuracy: 0.01)
    }

    // MARK: - Actionable Funds Edge Cases

    func testActionableFundsDerivativesSkipped() {
        var config = FundConfig()
        config.fund_type = .derivatives
        config.status = .active
        config.interval_days = 1
        let entries = [FundEntry(date: "2025-01-01", value: 1000)]
        let fund = FundData(platform: "test", ticker: "PERP", config: config, entries: entries)

        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-15")
        XCTAssertEqual(actionable.count, 0)
    }

    func testActionableFundsNoEntries() {
        let config = makeConfig()
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: [])

        // 2025-03-14 is a Friday (trading day for stocks)
        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-14")
        // New funds with no entries are immediately actionable (need first action)
        XCTAssertEqual(actionable.count, 1)
        XCTAssertEqual(actionable.first?.fund.id, fund.id)
    }

    func testActionableFundsNotYetDue() {
        var config = makeConfig()
        config.interval_days = 7
        let entries = [FundEntry(date: "2025-03-13", value: 1000, action: .BUY, amount: 500)]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-14")
        XCTAssertEqual(actionable.count, 0) // Only 1 day since last entry, interval is 7
    }

    func testActionableFundsDueToday() {
        var config = makeConfig()
        config.interval_days = 7
        let entries = [FundEntry(date: "2025-03-07", value: 1000, action: .BUY, amount: 500)]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        // 2025-03-14 is a Friday (trading day)
        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-14")
        XCTAssertEqual(actionable.count, 1)
        XCTAssertEqual(actionable[0].daysOverdue, 0)
    }

    func testActionableFundsSortedByOverdue() {
        let config = makeConfig()
        let fund1 = FundData(platform: "test", ticker: "A", config: config,
                             entries: [FundEntry(date: "2025-02-01", value: 1000, action: .BUY, amount: 100)])
        let fund2 = FundData(platform: "test", ticker: "B", config: config,
                             entries: [FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 100)])

        // 2025-03-14 is a Friday (trading day)
        let actionable = computeActionableFunds([fund1, fund2], asOfDate: "2025-03-14")
        XCTAssertEqual(actionable.count, 2)
        // fund2 is more overdue (older last entry)
        XCTAssertGreaterThan(actionable[0].daysOverdue, actionable[1].daysOverdue)
    }

    /// Reproduces the M1 CASH / SAVE scenario: a trading fund with manage_cash=false
    /// draws from a platform cash fund whose balance is zero, but the trading fund has
    /// margin_enabled with available margin headroom — so buys can execute without cash.
    /// The cash fund should NOT trigger a "Deposit cash to start DCA" alert in that case.
    func testActionableFundsSkipsCashDepositWhenMarginAvailable() {
        // Trading fund: manage_cash=false, margin_enabled=true, overdue buy
        var trading = makeConfig(manageCash: false)
        trading.margin_enabled = true
        let tradingEntries = [
            FundEntry(date: "2025-02-01", value: 1000, action: .BUY, amount: 100,
                      margin_available: 500),
        ]
        let tradingFund = FundData(platform: "m1", ticker: "SAVE", config: trading, entries: tradingEntries)

        // Empty cash fund on same platform
        var cash = makeConfig(fundType: .cash)
        cash.manage_cash = true
        let cashFund = FundData(platform: "m1", ticker: "cash", config: cash,
                                entries: [FundEntry(date: "2025-02-01", value: 0, cash: 0)])

        // 2025-03-14 is a Friday — SAVE is overdue
        let actionable = computeActionableFunds([tradingFund, cashFund], asOfDate: "2025-03-14")

        // SAVE should be actionable, but the cash fund should NOT be flagged for deposit
        XCTAssertTrue(actionable.contains { $0.fund.id == tradingFund.id })
        XCTAssertFalse(actionable.contains { $0.needsCashDeposit },
                       "Cash fund must not alert when dependent fund has available margin")
    }

    /// Same scenario, but the trading fund has NO margin available — the cash fund
    /// alert is expected to fire because the overdue fund genuinely needs cash.
    func testActionableFundsFiresCashDepositWhenNoMargin() {
        var trading = makeConfig(manageCash: false)
        trading.margin_enabled = false
        let tradingEntries = [
            FundEntry(date: "2025-02-01", value: 1000, action: .BUY, amount: 100),
        ]
        let tradingFund = FundData(platform: "m1", ticker: "SAVE", config: trading, entries: tradingEntries)

        var cash = makeConfig(fundType: .cash)
        cash.manage_cash = true
        let cashFund = FundData(platform: "m1", ticker: "cash", config: cash,
                                entries: [FundEntry(date: "2025-02-01", value: 0, cash: 0)])

        let actionable = computeActionableFunds([tradingFund, cashFund], asOfDate: "2025-03-14")
        XCTAssertTrue(actionable.contains { $0.needsCashDeposit && $0.fund.id == cashFund.id })
    }

    // MARK: - Recommendation Edge Cases

    func testRecommendationNoFundType() {
        let config = FundConfig()
        let state = FundState()
        XCTAssertNil(computeRecommendation(config: config, state: state))
    }

    func testRecommendationManageCashFalse() {
        var config = makeConfig()
        config.manage_cash = false

        let state = FundState(
            cashAvailableUsd: 5000,
            expectedTargetUsd: 550,
            actualValueUsd: 500,
            startInputUsd: 500,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: -50
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .BUY)
        // When manage_cash=false, buy amount is the limit (not capped by cash)
        XCTAssertEqual(rec!.amount, 100, accuracy: 0.01)
    }

    func testRecommendationHoldWhenNoCashAndNoManage() {
        var config = makeConfig()
        config.manage_cash = false

        let state = FundState(
            cashAvailableUsd: 0,
            expectedTargetUsd: 550,
            actualValueUsd: 500,
            startInputUsd: 500,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: -50
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .HOLD)
    }

    // MARK: - FundSummary

    func testFundSummaryComputation() {
        let config = makeConfig()
        let entries = [
            FundEntry(date: "2024-06-01", value: 1000, action: .BUY, amount: 1000, shares: 20, fund_size: 5000),
            FundEntry(date: "2025-01-01", value: 1200, action: .HOLD, fund_size: 5000),
        ]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let summary = FundSummary(fund, asOfDate: "2025-01-01")

        XCTAssertFalse(summary.isCash)
        XCTAssertTrue(summary.features.allowsTrading)
        XCTAssertTrue(summary.features.allowsRecommendations)
        XCTAssertEqual(summary.currentValue, 1200, accuracy: 0.01)
        XCTAssertNotNil(summary.recommendation)
        XCTAssertNil(summary.closedMetrics)
    }

    func testFundSummaryClosedFund() {
        let config = makeConfig(status: .closed)
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20),
            FundEntry(date: "2024-06-01", value: 1200, action: .SELL, amount: 1200, shares: 20),
        ]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let summary = FundSummary(fund, asOfDate: "2025-01-01")

        XCTAssertNil(summary.recommendation)
        XCTAssertNotNil(summary.closedMetrics)
        XCTAssertEqual(summary.closedMetrics!.totalInvestedUsd, 1000, accuracy: 0.01)
        XCTAssertEqual(summary.closedMetrics!.totalReturnedUsd, 1200, accuracy: 0.01)
    }

    func testFundSummaryIsDueForAction() {
        var config = makeConfig()
        config.interval_days = 7
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500),
        ]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let summary = FundSummary(fund, asOfDate: "2025-01-15")
        // 14 days since last entry, interval is 7 -> due
        XCTAssertTrue(summary.isDueForAction)
    }

    // MARK: - Closed Fund Metrics Edge Cases

    func testClosedFundMetricsShortDuration() {
        let trades = [
            Trade(date: "2024-06-01", amountUsd: 1000, type: .buy),
            Trade(date: "2024-06-02", amountUsd: 1010, type: .sell),
        ]

        let metrics = computeClosedFundMetrics(
            trades: trades, dividends: [], expenses: [],
            cashInterest: 0, startDate: "2024-06-01", endDate: "2024-06-02"
        )

        XCTAssertEqual(metrics.totalInvestedUsd, 1000)
        XCTAssertEqual(metrics.totalReturnedUsd, 1010)
        XCTAssertEqual(metrics.netGainUsd, 10, accuracy: 0.01)
        XCTAssertEqual(metrics.durationDays, 1)
        // Very short duration: APY = returnPct directly (duration <= 3)
        XCTAssertEqual(metrics.apy, 0.01, accuracy: 0.001)
    }

    func testClosedFundMetricsLoss() {
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 1000, type: .buy),
            Trade(date: "2024-07-01", amountUsd: 800, type: .sell),
        ]

        let metrics = computeClosedFundMetrics(
            trades: trades, dividends: [], expenses: [],
            cashInterest: 0, startDate: "2024-01-01", endDate: "2024-07-01"
        )

        XCTAssertEqual(metrics.netGainUsd, -200, accuracy: 0.01)
        XCTAssertEqual(metrics.returnPct, -0.20, accuracy: 0.001)
        XCTAssertLessThan(metrics.apy, 0)
    }

    // MARK: - Closed Fund History Cache

    /// Produces a closed-fund FundData with a small known history.
    private func makeClosedFund(cashApy: Double = 0.044) -> FundData {
        var config = makeConfig(status: .closed, cashApy: cashApy)
        config.fund_type = .stock
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 10),
            FundEntry(date: "2024-06-01", value: 1200, action: .SELL, amount: 1200, shares: 10),
        ]
        return FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)
    }

    func testHistoryFingerprintIsDeterministic() {
        // Same fund instantiated twice must produce the same fingerprint — Swift's per-process-seeded
        // `Hasher` was the original bug; this guards against regressing to it.
        let a = makeClosedFund()
        let b = makeClosedFund()
        XCTAssertEqual(FundSummary.historyFingerprint(for: a), FundSummary.historyFingerprint(for: b))
        // SHA-256 hex string.
        XCTAssertEqual(FundSummary.historyFingerprint(for: a).count, 64)
    }

    func testHistoryFingerprintIsInvariantToEntryStorageOrder() {
        // Same entries in different storage order MUST produce the same fingerprint —
        // otherwise an out-of-order edit (or a TSV that wasn't appended chronologically)
        // would invalidate the cache despite identical metrics.
        var configA = makeConfig(status: .closed)
        configA.fund_type = .stock
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 10),
            FundEntry(date: "2024-03-15", value: 1100, action: .HOLD),
            FundEntry(date: "2024-06-01", value: 1200, action: .SELL, amount: 1200, shares: 10),
        ]
        let fundA = FundData(platform: "test", ticker: "AAPL", config: configA, entries: entries)
        let fundB = FundData(platform: "test", ticker: "AAPL", config: configA, entries: entries.reversed())
        XCTAssertEqual(FundSummary.historyFingerprint(for: fundA), FundSummary.historyFingerprint(for: fundB))
    }

    func testHistoryFingerprintChangesWhenEntriesChange() {
        var fund = makeClosedFund()
        let before = FundSummary.historyFingerprint(for: fund)
        fund.entries.append(FundEntry(date: "2024-07-01", value: 0, action: .WITHDRAW, amount: 1200))
        XCTAssertNotEqual(before, FundSummary.historyFingerprint(for: fund))
    }

    func testHistoryFingerprintChangesWhenCashAPYChanges() {
        // cash_apy feeds computeCashInterest → closed metrics. Fingerprint MUST react to it.
        let a = makeClosedFund(cashApy: 0.04)
        let b = makeClosedFund(cashApy: 0.05)
        XCTAssertNotEqual(FundSummary.historyFingerprint(for: a), FundSummary.historyFingerprint(for: b))
    }

    func testHistoryFingerprintDistinguishesNilFromSentinelValue() {
        // Regression: previous encoding used `?? -1` as a nil sentinel, so an entry with
        // `amount == -1` collided with `amount == nil`. New encoding uses explicit S/N tags.
        var configA = makeConfig(status: .closed)
        configA.fund_type = .stock
        let fundA = FundData(
            platform: "test", ticker: "AAPL", config: configA,
            entries: [FundEntry(date: "2024-01-01", value: 100, action: .BUY, amount: -1)]
        )
        let fundB = FundData(
            platform: "test", ticker: "AAPL", config: configA,
            entries: [FundEntry(date: "2024-01-01", value: 100, action: .BUY, amount: nil)]
        )
        XCTAssertNotEqual(FundSummary.historyFingerprint(for: fundA), FundSummary.historyFingerprint(for: fundB))
    }

    func testEmptyHistoryClosedFundProducesNoMetricsOrFingerprint() {
        // Empty entries → no real data to compute metrics from; getFundStartDate([]) returns
        // today and endDate would fall back to asOfDate, producing a negative durationDays
        // when asOfDate < today (backtest / historical view). Skip caching AND skip emitting
        // metrics so the UI's closedMetrics-nil branch shows nothing instead of garbage.
        var config = makeConfig(status: .closed)
        config.fund_type = .stock
        let fund = FundData(platform: "test", ticker: "EMPTY", config: config, entries: [])
        let summary = FundSummary(fund, asOfDate: "2025-01-01")
        XCTAssertNil(summary.closedHistoryFingerprint)
        XCTAssertNil(summary.closedMetrics)
    }

    func testClosedMetricsCacheHitReturnsStoredValue() {
        // Stash an obviously-wrong cached value under the *correct* fingerprint — if buildClosedMetrics
        // hits the cache, we get the wrong value back, proving the cache path is taken.
        var fund = makeClosedFund()
        let fingerprint = FundSummary.historyFingerprint(for: fund)
        let sentinel = ClosedFundMetrics(
            totalInvestedUsd: 99999, totalReturnedUsd: 88888,
            totalDividendsUsd: 0, totalCashInterestUsd: 0, totalExpensesUsd: 0,
            netGainUsd: 77777, returnPct: 0.5, apy: 1.5,
            startDate: "2024-01-01", endDate: "2024-06-01", durationDays: 365
        )
        fund.config.history_cache = FundHistoryCache(entryFingerprint: fingerprint, closedMetrics: sentinel)

        let summary = FundSummary(fund, asOfDate: "2025-01-01")
        XCTAssertEqual(summary.closedMetrics?.totalInvestedUsd, 99999)
        XCTAssertEqual(summary.closedMetrics?.netGainUsd, 77777)
    }

    func testClosedMetricsCacheMissOnFingerprintMismatch() throws {
        // Stale cache with a fingerprint that no longer matches — must be ignored and recomputed.
        var fund = makeClosedFund()
        let stale = ClosedFundMetrics(
            totalInvestedUsd: 99999, totalReturnedUsd: 88888,
            totalDividendsUsd: 0, totalCashInterestUsd: 0, totalExpensesUsd: 0,
            netGainUsd: 77777, returnPct: 0.5, apy: 1.5,
            startDate: "2024-01-01", endDate: "2024-06-01", durationDays: 365
        )
        fund.config.history_cache = FundHistoryCache(entryFingerprint: "stale-hash", closedMetrics: stale)

        let summary = FundSummary(fund, asOfDate: "2025-01-01")
        let metrics = try XCTUnwrap(summary.closedMetrics)
        XCTAssertEqual(metrics.totalInvestedUsd, 1000, accuracy: 0.01)
        XCTAssertEqual(metrics.totalReturnedUsd, 1200, accuracy: 0.01)
    }

    // MARK: - Audit Entries

    @MainActor func testBuildAuditEntries() {
        let fund1 = FundData(
            platform: "coinbase", ticker: "BTC",
            config: FundConfig(),
            entries: [
                FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500),
                FundEntry(date: "2025-01-08", value: 1100, action: .HOLD),
            ]
        )
        let fund2 = FundData(
            platform: "robinhood", ticker: "AAPL",
            config: FundConfig(),
            entries: [
                FundEntry(date: "2025-01-05", value: 200, action: .BUY, amount: 200),
            ]
        )

        let auditEntries = FundDataStore.buildAuditEntries(from: [fund1, fund2])
        XCTAssertEqual(auditEntries.count, 3)
        // Sorted reverse chronological
        XCTAssertEqual(auditEntries[0].date, "2025-01-08")
        XCTAssertEqual(auditEntries[1].date, "2025-01-05")
        XCTAssertEqual(auditEntries[2].date, "2025-01-01")
    }

    @MainActor func testBuildAuditEntriesEmpty() {
        let entries = FundDataStore.buildAuditEntries(from: [])
        XCTAssertEqual(entries.count, 0)
    }
}
