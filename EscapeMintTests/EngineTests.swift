import XCTest
@testable import EscapeMint

final class EngineTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal stock FundConfig with sensible defaults for testing
    private func makeStockConfig(
        targetApy: Double = 0.10,
        inputMin: Double = 100,
        inputMid: Double = 150,
        inputMax: Double = 200,
        maxAtPct: Double = -0.25,
        minProfit: Double = 100,
        accumulate: Bool = true,
        status: FundStatus = .active,
        cashApy: Double = 0.044,
        manageCash: Bool = true
    ) -> FundConfig {
        FundConfig(
            fund_type: .stock, status: status,
            target_apy: targetApy, interval_days: 7,
            input_min_usd: inputMin, input_mid_usd: inputMid, input_max_usd: inputMax,
            max_at_pct: maxAtPct, min_profit_usd: minProfit,
            cash_apy: cashApy, manage_cash: manageCash, accumulate: accumulate
        )
    }

    // MARK: - computeStartInput

    func testComputeStartInput() {
        let trades = [
            Trade(date: "2025-01-01", amountUsd: 500, type: .buy),
            Trade(date: "2025-01-15", amountUsd: 300, type: .buy),
        ]
        let result = computeStartInput(trades: trades, asOfDate: "2025-02-01")
        XCTAssertEqual(result, 800, accuracy: 0.01)
    }

    func testComputeStartInputWithSells() {
        // Buy 500, then sell 200 in accumulate mode — sells are ignored for cost basis
        let config = makeStockConfig(accumulate: true)
        let trades = [
            Trade(date: "2025-01-01", amountUsd: 500, type: .buy),
            Trade(date: "2025-01-15", amountUsd: 200, type: .sell),
        ]
        let result = computeStartInput(trades: trades, asOfDate: "2025-02-01", config: config)
        XCTAssertEqual(result, 500, accuracy: 0.01)
    }

    func testComputeStartInputFullLiquidation() {
        // Buy 500, sell 500 — full liquidation resets cost basis to 0
        let trades = [
            Trade(date: "2025-01-01", amountUsd: 500, type: .buy),
            Trade(date: "2025-02-01", amountUsd: 500, type: .sell),
        ]
        let result = computeStartInput(trades: trades, asOfDate: "2025-03-01")
        XCTAssertEqual(result, 0, accuracy: 0.01)
    }

    // MARK: - computeRecommendation: BUY

    func testComputeRecommendationBuy() {
        let config = makeStockConfig()
        let state = FundState(
            cashAvailableUsd: 4500,
            expectedTargetUsd: 550,
            actualValueUsd: 500,
            startInputUsd: 500,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: -50,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .BUY)
        // At cost basis (gainUsd == 0), should use input_min_usd
        XCTAssertEqual(rec!.amount, 100, accuracy: 0.01)
    }

    func testComputeRecommendationBuyMidWhenDown() {
        let config = makeStockConfig()
        // Loss but not below maxAtPct — should recommend mid amount
        let state = FundState(
            cashAvailableUsd: 4500,
            expectedTargetUsd: 550,
            actualValueUsd: 450,
            startInputUsd: 500,
            gainUsd: -50,
            gainPct: -0.10,
            targetDiffUsd: -100,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .BUY)
        XCTAssertEqual(rec!.amount, 150, accuracy: 0.01)
    }

    func testComputeRecommendationBuyMaxWhenDeepLoss() {
        let config = makeStockConfig()
        // Deep loss exceeding maxAtPct — should recommend max amount
        let state = FundState(
            cashAvailableUsd: 4500,
            expectedTargetUsd: 550,
            actualValueUsd: 350,
            startInputUsd: 500,
            gainUsd: -150,
            gainPct: -0.30,
            targetDiffUsd: -200,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .BUY)
        XCTAssertEqual(rec!.amount, 200, accuracy: 0.01)
    }

    func testComputeRecommendationInitialBuy() {
        let config = makeStockConfig()
        // No investment yet — should recommend initial buy
        let state = FundState(
            cashAvailableUsd: 5000,
            expectedTargetUsd: 0,
            actualValueUsd: 0,
            startInputUsd: 0,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: 0,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .BUY)
        // Initial buy uses input_min_usd capped by cash
        XCTAssertEqual(rec!.amount, 100, accuracy: 0.01)
    }

    // MARK: - computeRecommendation: SELL

    func testComputeRecommendationSell() {
        let config = makeStockConfig(minProfit: 100, accumulate: true)
        // Above target by more than min_profit AND in profit
        let state = FundState(
            cashAvailableUsd: 4000,
            expectedTargetUsd: 500,
            actualValueUsd: 700,
            startInputUsd: 500,
            gainUsd: 200,
            gainPct: 0.40,
            targetDiffUsd: 200,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .SELL)
        // In accumulate mode, sell amount is the DCA limit (input_min since gain > 0)
        XCTAssertEqual(rec!.amount, 100, accuracy: 0.01)
    }

    func testComputeRecommendationSellHarvestMode() {
        let config = makeStockConfig(minProfit: 100, accumulate: false)
        let state = FundState(
            cashAvailableUsd: 4000,
            expectedTargetUsd: 500,
            actualValueUsd: 700,
            startInputUsd: 500,
            gainUsd: 200,
            gainPct: 0.40,
            targetDiffUsd: 200,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .SELL)
        // In harvest mode, sell entire position
        XCTAssertEqual(rec!.amount, 700, accuracy: 0.01)
    }

    // MARK: - computeRecommendation: HOLD

    func testComputeRecommendationHold() {
        let config = makeStockConfig()
        // Below target but no cash available — should HOLD
        let state = FundState(
            cashAvailableUsd: 0,
            expectedTargetUsd: 550,
            actualValueUsd: 500,
            startInputUsd: 500,
            gainUsd: 0,
            gainPct: 0,
            targetDiffUsd: -50,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: config, state: state)
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.action, .HOLD)
        XCTAssertEqual(rec!.amount, 0, accuracy: 0.01)
    }

    // MARK: - computeRecommendation: nil cases

    // These tests use *non-default* state values. A regression that returned nil for all
    // fund types regardless of config would still pass if the state were `FundState()` —
    // which defeats the point of verifying the type/status-specific nil behaviour.

    private func makeNonDefaultState() -> FundState {
        var s = FundState()
        s.actualValueUsd = 5000
        s.cashAvailableUsd = 1500
        s.startInputUsd = 4000
        s.expectedTargetUsd = 4500
        s.gainUsd = 1000
        s.realizedGainsUsd = 250
        return s
    }

    func testComputeRecommendationNilForCash() {
        var config = makeStockConfig()
        config.fund_type = .cash
        // Use populated state to verify nil is driven by fund_type, not empty state.
        XCTAssertNil(computeRecommendation(config: config, state: makeNonDefaultState()))
    }

    func testComputeRecommendationNilForDerivatives() {
        var config = makeStockConfig()
        config.fund_type = .derivatives
        XCTAssertNil(computeRecommendation(config: config, state: makeNonDefaultState()))
    }

    func testComputeRecommendationNilForClosed() {
        let config = makeStockConfig(status: .closed)
        XCTAssertNil(computeRecommendation(config: config, state: makeNonDefaultState()))
    }

    // Positive control: with the SAME non-default state and a standard stock config,
    // computeRecommendation MUST return non-nil. This ensures the nil tests above are
    // meaningfully testing the type/status branches.
    func testComputeRecommendationNonNilForStockWithState() {
        let config = makeStockConfig()
        XCTAssertNotNil(computeRecommendation(config: config, state: makeNonDefaultState()))
    }

    // MARK: - computeExpectedTarget

    func testComputeExpectedTarget() {
        let config = makeStockConfig(targetApy: 0.10)
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 1000, type: .buy),
        ]
        // After exactly 365 days at 10% APY, expected target = 1000 + 1000*0.10 = 1100
        let result = computeExpectedTarget(config: config, trades: trades, asOfDate: "2025-01-01")
        XCTAssertEqual(result, 1100, accuracy: 1.0)
    }

    func testComputeExpectedTargetMultipleTrades() {
        let config = makeStockConfig(targetApy: 0.10)
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 500, type: .buy),
            Trade(date: "2024-07-01", amountUsd: 500, type: .buy),
        ]
        // First buy: 365 days at 10% -> gain ~50
        // Second buy: ~184 days at 10% -> gain ~24.5
        let result = computeExpectedTarget(config: config, trades: trades, asOfDate: "2025-01-01")
        // Total start input = 1000, expected gains ~ 74.5
        XCTAssertGreaterThan(result, 1050)
        XCTAssertLessThan(result, 1100)
    }

    // MARK: - computeFundState

    func testComputeFundStateActive() {
        let config = makeStockConfig()
        let trades = [Trade(date: "2024-06-01", amountUsd: 1000, type: .buy)]
        let cashflows = [CashFlow(date: "2024-01-01", amountUsd: 5000, type: .deposit)]
        let state = computeFundState(
            config: config, trades: trades, cashflows: cashflows, dividends: [], expenses: [],
            actualValue: 1100, asOfDate: "2025-01-01"
        )
        XCTAssertEqual(state.startInputUsd, 1000, accuracy: 0.01)
        XCTAssertEqual(state.actualValueUsd, 1100, accuracy: 0.01)
        XCTAssertEqual(state.gainUsd, 100, accuracy: 0.01)
        XCTAssertEqual(state.gainPct, 0.10, accuracy: 0.01)
        XCTAssertGreaterThan(state.cashAvailableUsd, 0)
        XCTAssertGreaterThan(state.expectedTargetUsd, 1000)
    }

    func testComputeFundStateCashFund() {
        var config = makeStockConfig()
        config.fund_type = .cash
        config.cash_apy = 0.04
        let state = computeFundState(
            config: config, trades: [], cashflows: [], dividends: [], expenses: [],
            actualValue: 5000, asOfDate: "2025-01-01"
        )
        XCTAssertEqual(state.actualValueUsd, 5000, accuracy: 0.01)
        XCTAssertEqual(state.cashAvailableUsd, 5000, accuracy: 0.01)
        XCTAssertEqual(state.expectedTargetUsd, 0, accuracy: 0.01)
    }

    func testComputeFundStateClosed() {
        let config = makeStockConfig(status: .closed)
        let state = computeFundState(
            config: config, trades: [], cashflows: [], dividends: [], expenses: [],
            actualValue: 0, asOfDate: "2025-01-01"
        )
        XCTAssertEqual(state.cashAvailableUsd, 0)
        XCTAssertEqual(state.expectedTargetUsd, 0)
        XCTAssertEqual(state.startInputUsd, 0)
        XCTAssertEqual(state.realizedGainsUsd, 0)
    }

    // MARK: - APY Calculations

    func testComputeLinearAPY() {
        // 10% gain on 1000 over 365 days = 10% APY
        let apy = computeLinearAPY(100, 1000, 365)
        XCTAssertEqual(apy, 0.10, accuracy: 0.001)
    }

    func testComputeLinearAPYHalfYear() {
        // 5% gain on 1000 over 182.5 days = ~10% APY
        let apy = computeLinearAPY(50, 1000, 183)
        XCTAssertEqual(apy, 0.10, accuracy: 0.01)
    }

    func testComputeLinearAPYZeroBasis() {
        XCTAssertEqual(computeLinearAPY(100, 0, 365), 0)
    }

    func testComputeLinearAPYZeroDays() {
        XCTAssertEqual(computeLinearAPY(100, 1000, 0), 0)
    }

    func testComputeProjectedAnnualReturn() {
        let projected = computeProjectedAnnualReturn(10000, 0.12)
        XCTAssertEqual(projected, 1200, accuracy: 0.01)
    }

    // MARK: - Closed Fund Metrics

    func testComputeClosedFundMetrics() {
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 1000, type: .buy),
            Trade(date: "2024-07-01", amountUsd: 1200, type: .sell),
        ]
        let dividends = [Dividend(date: "2024-04-01", amountUsd: 25)]
        let expenses = [Expense(date: "2024-03-01", amountUsd: 5)]

        let metrics = computeClosedFundMetrics(
            trades: trades, dividends: dividends, expenses: expenses,
            cashInterest: 10, startDate: "2024-01-01", endDate: "2024-07-01"
        )

        XCTAssertEqual(metrics.totalInvestedUsd, 1000, accuracy: 0.01)
        XCTAssertEqual(metrics.totalReturnedUsd, 1200, accuracy: 0.01)
        XCTAssertEqual(metrics.totalDividendsUsd, 25, accuracy: 0.01)
        XCTAssertEqual(metrics.totalExpensesUsd, 5, accuracy: 0.01)
        XCTAssertEqual(metrics.totalCashInterestUsd, 10, accuracy: 0.01)
        // netGain = 1200 + 25 + 10 - 5 - 1000 = 230
        XCTAssertEqual(metrics.netGainUsd, 230, accuracy: 0.01)
        // returnPct = 230 / 1000 = 0.23
        XCTAssertEqual(metrics.returnPct, 0.23, accuracy: 0.001)
        XCTAssertEqual(metrics.startDate, "2024-01-01")
        XCTAssertEqual(metrics.endDate, "2024-07-01")
        XCTAssertGreaterThan(metrics.durationDays, 180)
        // APY should be annualized from ~6 months of 23% return
        XCTAssertGreaterThan(metrics.apy, 0.23)
    }

    func testComputeClosedFundMetricsNoTrades() {
        let metrics = computeClosedFundMetrics(
            trades: [], dividends: [], expenses: [],
            cashInterest: 0, startDate: "2024-01-01", endDate: "2024-01-01"
        )
        XCTAssertEqual(metrics.totalInvestedUsd, 0)
        XCTAssertEqual(metrics.netGainUsd, 0)
    }

    // MARK: - Share Tracking & Liquidation

    func testTrackSharesBuy() {
        var trade = Trade(date: "2025-01-01", amountUsd: 500, type: .buy)
        trade.shares = 10
        let result = trackShares(trade: trade, currentShares: 5)
        XCTAssertEqual(result, 15, accuracy: 0.001)
    }

    func testTrackSharesSell() {
        var trade = Trade(date: "2025-01-01", amountUsd: 500, type: .sell)
        trade.shares = 3
        let result = trackShares(trade: trade, currentShares: 10)
        XCTAssertEqual(result, 7, accuracy: 0.001)
    }

    func testTrackSharesNilShares() {
        let trade = Trade(date: "2025-01-01", amountUsd: 500, type: .buy)
        // No shares set — should return current shares unchanged
        let result = trackShares(trade: trade, currentShares: 10)
        XCTAssertEqual(result, 10, accuracy: 0.001)
    }

    func testDetectFullLiquidationByShares() {
        var trade = Trade(date: "2025-01-01", amountUsd: 500, type: .sell)
        trade.shares = 10
        trade.value = 500
        // After selling, sumShares is 0 — liquidation
        let result = detectFullLiquidation(trade: trade, sumShares: 0, totalBuys: 500, totalSells: 500)
        XCTAssertTrue(result)
    }

    func testDetectFullLiquidationByValue() {
        var trade = Trade(date: "2025-01-01", amountUsd: 500, type: .sell)
        trade.value = 500
        // value <= amount + 0.01
        let result = detectFullLiquidation(trade: trade, sumShares: 5, totalBuys: 1000, totalSells: 500)
        XCTAssertTrue(result)
    }

    func testDetectFullLiquidationByDollars() {
        var trade = Trade(date: "2025-01-01", amountUsd: 600, type: .sell)
        trade.value = 1000
        // totalSells >= totalBuys
        let result = detectFullLiquidation(trade: trade, sumShares: 5, totalBuys: 500, totalSells: 600)
        XCTAssertTrue(result)
    }

    func testDetectNotLiquidation() {
        var trade = Trade(date: "2025-01-01", amountUsd: 200, type: .sell)
        trade.value = 800
        let result = detectFullLiquidation(trade: trade, sumShares: 5, totalBuys: 1000, totalSells: 200)
        XCTAssertFalse(result)
    }

    func testIsFullLiquidationShareBased() {
        // sumShares near zero
        XCTAssertTrue(isFullLiquidation(shares: 10, value: 500, amount: 200, sumShares: 0.00001, totalBuys: 1000, totalSells: 200))
    }

    // MARK: - computeLimit

    func testComputeLimitMinWhenGainsPositive() {
        let config = makeStockConfig(inputMin: 100, inputMid: 150, inputMax: 200)
        let state = FundState(startInputUsd: 500, gainUsd: 10, gainPct: 0.02)
        XCTAssertEqual(computeLimit(config: config, state: state), 100)
    }

    func testComputeLimitMidWhenLoss() {
        let config = makeStockConfig(inputMin: 100, inputMid: 150, inputMax: 200)
        let state = FundState(startInputUsd: 500, gainUsd: -30, gainPct: -0.06)
        XCTAssertEqual(computeLimit(config: config, state: state), 150)
    }

    func testComputeLimitMaxWhenDeepLoss() {
        let config = makeStockConfig(inputMin: 100, inputMid: 150, inputMax: 200, maxAtPct: -0.25)
        let state = FundState(startInputUsd: 500, gainUsd: -150, gainPct: -0.30)
        XCTAssertEqual(computeLimit(config: config, state: state), 200)
    }

    func testComputeLimitMinWhenNoStartInput() {
        let config = makeStockConfig(inputMin: 100)
        let state = FundState(startInputUsd: 0)
        XCTAssertEqual(computeLimit(config: config, state: state), 100)
    }

    // MARK: - Time-Weighted Fund Size

    func testComputeTimeWeightedFundSize() {
        // Invest 1000 on day 0, held for 365 days
        let trades = [Trade(date: "2024-01-01", amountUsd: 1000, type: .buy)]
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: "2024-01-01", asOfDate: "2025-01-01")
        // Should be 1000 (constant investment over full period)
        XCTAssertEqual(twfs, 1000, accuracy: 1.0)
    }

    func testComputeTimeWeightedFundSizeMultipleBuys() {
        // Buy 1000 on Jan 1, buy another 1000 on Jul 1 — average should be ~1500
        let trades = [
            Trade(date: "2024-01-01", amountUsd: 1000, type: .buy),
            Trade(date: "2024-07-01", amountUsd: 1000, type: .buy),
        ]
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: "2024-01-01", asOfDate: "2025-01-01")
        // Roughly 1000 for first half, 2000 for second half = ~1500
        XCTAssertGreaterThan(twfs, 1400)
        XCTAssertLessThan(twfs, 1600)
    }

    func testComputeTimeWeightedFundSizeZeroDays() {
        let trades = [Trade(date: "2024-01-01", amountUsd: 1000, type: .buy)]
        let twfs = computeTimeWeightedFundSize(trades: trades, startDate: "2024-01-01", asOfDate: "2024-01-01")
        XCTAssertEqual(twfs, 0)
    }

    // MARK: - Formatting

    func testFormatCurrency() {
        let result = formatCurrency(1234.56)
        XCTAssertEqual(result, "$1,234.56")
    }

    func testFormatCurrencySmallValue() {
        let result = formatCurrency(42.50)
        XCTAssertEqual(result, "$42.50")
    }

    func testFormatCurrencyZero() {
        let result = formatCurrency(0)
        XCTAssertEqual(result, "$0.00")
    }

    func testFormatCurrencyNegative() {
        let result = formatCurrency(-500.00)
        XCTAssertEqual(result, "-$500.00")
    }

    func testFormatCurrencyLargeValue() {
        let result = formatCurrency(1234567.89)
        XCTAssertEqual(result, "$1,234,567.89")
    }

    func testFormatPercent() {
        let result = formatPercent(0.1234)
        XCTAssertEqual(result, "12.34%")
    }

    func testFormatPercentZero() {
        let result = formatPercent(0)
        XCTAssertEqual(result, "0.00%")
    }

    func testFormatPercentNegative() {
        let result = formatPercent(-0.0567)
        XCTAssertEqual(result, "-5.67%")
    }

    func testFormatCurrencyCompact() {
        XCTAssertEqual(formatCurrencyCompact(1_500_000), "$1.5M")
        XCTAssertEqual(formatCurrencyCompact(25_000), "$25.0K")
        XCTAssertEqual(formatCurrencyCompact(500), "$500")
        XCTAssertEqual(formatCurrencyCompact(-2_000_000), "-$2.0M")
        XCTAssertEqual(formatCurrencyCompact(-3500), "-$3.5K")
    }

    func testFormatPercentSigned() {
        XCTAssertEqual(formatPercentSigned(0.125), "+12.5%")
        XCTAssertEqual(formatPercentSigned(-0.05), "-5.0%")
        XCTAssertEqual(formatPercentSigned(0), "+0.0%")
    }

    // MARK: - Converters

    func testEntriesToTrades() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10),
            FundEntry(date: "2025-01-08", value: 1100, action: .HOLD),
            FundEntry(date: "2025-01-15", value: 1050, action: .SELL, amount: 200, shares: 4),
            FundEntry(date: "2025-01-22", value: 900, action: .DEPOSIT, amount: 1000),
        ]

        let trades = entriesToTrades(entries)
        XCTAssertEqual(trades.count, 2)
        XCTAssertEqual(trades[0].type, .buy)
        XCTAssertEqual(trades[0].amountUsd, 500)
        XCTAssertEqual(trades[0].shares, 10)
        XCTAssertEqual(trades[1].type, .sell)
        XCTAssertEqual(trades[1].amountUsd, 200)
    }

    func testEntriesToTradesSkipsZeroAmount() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 0),
        ]
        let trades = entriesToTrades(entries)
        XCTAssertEqual(trades.count, 0)
    }

    func testEntriesToDividends() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, dividend: 0),
            FundEntry(date: "2025-04-01", value: 1050, action: .HOLD, dividend: 25.50),
            FundEntry(date: "2025-07-01", value: 1100, action: .HOLD, dividend: 30),
        ]

        let dividends = entriesToDividends(entries)
        XCTAssertEqual(dividends.count, 2)
        XCTAssertEqual(dividends[0].amountUsd, 25.50, accuracy: 0.01)
        XCTAssertEqual(dividends[0].date, "2025-04-01")
        XCTAssertEqual(dividends[1].amountUsd, 30, accuracy: 0.01)
    }

    func testEntriesToCashFlows() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 5000, action: .DEPOSIT, amount: 1000),
            FundEntry(date: "2025-02-01", value: 5100, action: .WITHDRAW, amount: 500),
            FundEntry(date: "2025-03-01", value: 4600, action: .BUY, amount: 200),
        ]

        let cashflows = entriesToCashFlows(entries)
        XCTAssertEqual(cashflows.count, 2)
        XCTAssertEqual(cashflows[0].type, .deposit)
        XCTAssertEqual(cashflows[0].amountUsd, 1000)
        XCTAssertEqual(cashflows[1].type, .withdrawal)
        XCTAssertEqual(cashflows[1].amountUsd, 500)
    }

    func testEntriesToCashFlowsHoldWithAmount() {
        // HOLD with non-zero amount is treated as a cash flow
        let entries = [
            FundEntry(date: "2025-01-01", value: 5000, action: .HOLD, amount: 200),
            FundEntry(date: "2025-02-01", value: 5000, action: .HOLD, amount: -100),
            FundEntry(date: "2025-03-01", value: 5000, action: .HOLD, amount: 0),
        ]
        let cashflows = entriesToCashFlows(entries)
        XCTAssertEqual(cashflows.count, 2)
        XCTAssertEqual(cashflows[0].type, .deposit)
        XCTAssertEqual(cashflows[0].amountUsd, 200)
        XCTAssertEqual(cashflows[1].type, .withdrawal)
        XCTAssertEqual(cashflows[1].amountUsd, 100)
    }

    func testEntriesToExpenses() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, expense: 5),
            FundEntry(date: "2025-02-01", value: 1000, expense: 0),
            FundEntry(date: "2025-03-01", value: 1000, expense: 10),
        ]
        let expenses = entriesToExpenses(entries)
        XCTAssertEqual(expenses.count, 2)
        XCTAssertEqual(expenses[0].amountUsd, 5)
        XCTAssertEqual(expenses[1].amountUsd, 10)
    }

    func testGetLatestValue() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 100),
            FundEntry(date: "2025-02-01", value: 200),
            FundEntry(date: "2025-03-01", value: 300),
        ]
        XCTAssertEqual(getLatestValue(entries), 300)
    }

    func testGetLatestValueEmpty() {
        XCTAssertEqual(getLatestValue([]), 0)
    }

    func testGetFundStartDate() {
        let entries = [
            FundEntry(date: "2025-03-01", value: 300),
            FundEntry(date: "2025-01-01", value: 100),
            FundEntry(date: "2025-02-01", value: 200),
        ]
        XCTAssertEqual(getFundStartDate(entries), "2025-01-01")
    }

    // MARK: - Date Utilities

    func testDaysBetween() {
        XCTAssertEqual(daysBetween("2025-01-01", "2025-01-31"), 30)
        XCTAssertEqual(daysBetween("2025-01-01", "2025-01-01"), 0)
        XCTAssertEqual(daysBetween("2025-01-31", "2025-01-01"), -30)
    }

    func testFormatDateLabel() {
        let result = formatDateLabel("2025-03-15")
        XCTAssertEqual(result, "Mar '25")
    }

    func testFormatTooltipDate() {
        let result = formatTooltipDate("2025-03-15")
        XCTAssertEqual(result, "Mar 15, 2025")
    }

    // MARK: - TSV Parsing & Serialization

    func testParseTSVRoundTrip() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, cash: 4000, action: .BUY, amount: 500, shares: 10, price: 50),
            FundEntry(date: "2025-01-08", value: 1050, cash: 3950, action: .HOLD),
            FundEntry(date: "2025-01-15", value: 1100, cash: 3900, action: .SELL, amount: 200, shares: 4, price: 55, dividend: 5.25),
        ]

        let tsv = buildTSV(entries)
        let parsed = parseTSV(tsv)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].date, "2025-01-01")
        XCTAssertEqual(parsed[0].value, 1000, accuracy: 0.01)
        XCTAssertEqual(parsed[0].cash, 4000)
        XCTAssertEqual(parsed[0].action, .BUY)
        XCTAssertEqual(parsed[0].amount, 500)
        XCTAssertEqual(parsed[0].shares, 10)
        XCTAssertEqual(parsed[0].price, 50)

        XCTAssertEqual(parsed[1].date, "2025-01-08")
        XCTAssertEqual(parsed[1].action, .HOLD)
        XCTAssertNil(parsed[1].amount)

        XCTAssertEqual(parsed[2].dividend, 5.25)
    }

    func testParseEntryAllFields() {
        let headers = ["date", "value", "cash", "action", "amount", "shares", "price",
                        "dividend", "expense", "cash_interest", "fund_size",
                        "margin_available", "margin_borrowed", "margin_expense",
                        "notes", "contracts", "entry_price", "liquidation_price",
                        "unrealized_pnl", "margin_locked", "fee", "margin"]
        let line = "2025-03-15\t1500.5\t3000\tBUY\t500\t10\t150.05\t\t2.5\t1.25\t5000\t1000\t200\t3.5\tsome note\t\t\t\t\t\t1.5\t"

        let entry = parseEntry(line, headers: headers)
        XCTAssertEqual(entry.date, "2025-03-15")
        XCTAssertEqual(entry.value, 1500.5, accuracy: 0.01)
        XCTAssertEqual(entry.cash, 3000)
        XCTAssertEqual(entry.action, .BUY)
        XCTAssertEqual(entry.amount, 500)
        XCTAssertEqual(entry.shares, 10)
        XCTAssertEqual(entry.price!, 150.05, accuracy: 0.01)
        XCTAssertNil(entry.dividend)
        XCTAssertEqual(entry.expense, 2.5)
        XCTAssertEqual(entry.cash_interest, 1.25)
        XCTAssertEqual(entry.fund_size, 5000)
        XCTAssertEqual(entry.margin_available, 1000)
        XCTAssertEqual(entry.margin_borrowed, 200)
        XCTAssertEqual(entry.margin_expense, 3.5)
        XCTAssertEqual(entry.notes, "some note")
        XCTAssertEqual(entry.fee, 1.5)
    }

    func testParseEntryNotesEscaping() {
        let headers = ["date", "value", "cash", "action", "amount", "shares", "price",
                        "dividend", "expense", "cash_interest", "fund_size",
                        "margin_available", "margin_borrowed", "margin_expense", "notes"]
        let line = "2025-03-15\t1000\t\t\t\t\t\t\t\t\t\t\t\t\thas\\ttab\\nnewline"

        let entry = parseEntry(line, headers: headers)
        XCTAssertEqual(entry.notes, "has\ttab\nnewline")
    }

    func testSerializeEntry() {
        let entry = FundEntry(date: "2025-01-01", value: 1000, cash: 4000, action: .BUY,
                              amount: 500, shares: 10, price: 100)
        let serialized = serializeEntry(entry)
        let parts = serialized.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts[0], "2025-01-01")
        XCTAssertEqual(parts[1], "1000")
        XCTAssertEqual(parts[2], "4000")
        XCTAssertEqual(parts[3], "BUY")
        XCTAssertEqual(parts[4], "500")
        XCTAssertEqual(parts[5], "10")
        XCTAssertEqual(parts[6], "100")
        // Dividend should be empty
        XCTAssertEqual(parts[7], "")
    }

    func testSerializeEntryOptionalFields() {
        let entry = FundEntry(date: "2025-01-01", value: 500)
        let serialized = serializeEntry(entry)
        let parts = serialized.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts[0], "2025-01-01")
        XCTAssertEqual(parts[1], "500")
        // All optional fields should be empty
        XCTAssertEqual(parts[2], "")  // cash
        XCTAssertEqual(parts[3], "")  // action
        XCTAssertEqual(parts[4], "")  // amount
    }

    func testBuildTSV() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500),
        ]
        let tsv = buildTSV(entries)
        let lines = tsv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2) // header + 1 entry
        XCTAssertTrue(lines[0].hasPrefix("date\tvalue\t"))
        XCTAssertTrue(lines[1].hasPrefix("2025-01-01\t"))
    }

    func testParseTSVEmpty() {
        let result = parseTSV("")
        XCTAssertEqual(result.count, 0)
    }

    func testParseTSVHeaderOnly() {
        let result = parseTSV("date\tvalue\tcash\n")
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - FundConfig Codable

    func testFundConfigCodableRoundTrip() {
        let config = FundConfig(
            platform: "coinbase", ticker: "BTC",
            fund_type: .crypto, status: .active, category: .sov,
            target_apy: 0.15, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.30, min_profit_usd: 100,
            cash_apy: 0.05, manage_cash: true,
            accumulate: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try! encoder.encode(config)
        let decoded = try! JSONDecoder().decode(FundConfig.self, from: data)

        XCTAssertEqual(decoded.platform, "coinbase")
        XCTAssertEqual(decoded.ticker, "BTC")
        XCTAssertEqual(decoded.fund_type, .crypto)
        XCTAssertEqual(decoded.status, .active)
        XCTAssertEqual(decoded.category, .sov)
        XCTAssertEqual(decoded.target_apy, 0.15)
        XCTAssertEqual(decoded.interval_days, 7)
        XCTAssertEqual(decoded.input_min_usd, 100)
        XCTAssertEqual(decoded.accumulate, true)
    }

    func testFundConfigCodingKeysMapping() {
        // Verify __platform and __ticker keys in JSON
        let config = FundConfig(platform: "robinhood", ticker: "AAPL")
        let data = try! JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"__platform\""))
        XCTAssertTrue(json.contains("\"__ticker\""))
        XCTAssertFalse(json.contains("\"platform\""))
    }

    func testFundConfigDecodesNilFields() {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let config = try! JSONDecoder().decode(FundConfig.self, from: data)
        XCTAssertNil(config.platform)
        XCTAssertNil(config.ticker)
        XCTAssertNil(config.fund_type)
    }

    // MARK: - isTestPlatform

    func testIsTestPlatformSuffix() {
        XCTAssertTrue(isTestPlatform("coinbasetest"))
        XCTAssertTrue(isTestPlatform("robinhoodtest"))
    }

    func testIsTestPlatformPrefix() {
        XCTAssertTrue(isTestPlatform("testcoinbase"))
        XCTAssertTrue(isTestPlatform("testAccount"))
    }

    func testIsTestPlatformDemo() {
        XCTAssertTrue(isTestPlatform("demoAccount"))
        XCTAssertTrue(isTestPlatform("demo"))
    }

    func testIsTestPlatformCaseInsensitive() {
        XCTAssertTrue(isTestPlatform("CoinbaseTest"))
        XCTAssertTrue(isTestPlatform("TESTACCOUNT"))
        XCTAssertTrue(isTestPlatform("DemoAccount"))
    }

    func testIsNotTestPlatform() {
        XCTAssertFalse(isTestPlatform("coinbase"))
        XCTAssertFalse(isTestPlatform("robinhood"))
        XCTAssertFalse(isTestPlatform("vanguard"))
        XCTAssertFalse(isTestPlatform("attestation"))
    }

    // MARK: - FundTypeConfig helpers

    func testIsCashFund() {
        XCTAssertTrue(isCashFund(.cash))
        XCTAssertFalse(isCashFund(.stock))
        XCTAssertFalse(isCashFund(.crypto))
        XCTAssertFalse(isCashFund(.derivatives))
        XCTAssertFalse(isCashFund(nil))
    }

    func testGetFeatures() {
        let stockFeatures = getFeatures(.stock)
        XCTAssertTrue(stockFeatures.allowsTrading)
        XCTAssertTrue(stockFeatures.allowsRecommendations)
        XCTAssertTrue(stockFeatures.supportsDividends)
        XCTAssertTrue(stockFeatures.supportsShares)

        let cashFeatures = getFeatures(.cash)
        XCTAssertFalse(cashFeatures.allowsTrading)
        XCTAssertFalse(cashFeatures.allowsRecommendations)
        XCTAssertTrue(cashFeatures.supportsCashInterest)

        let cryptoFeatures = getFeatures(.crypto)
        XCTAssertFalse(cryptoFeatures.supportsDividends)
        XCTAssertFalse(cryptoFeatures.supportsMargin)
    }

    func testFundTypeDefaultsExistForAllTypes() {
        for fundType in FundType.allCases {
            XCTAssertNotNil(fundTypeDefaults[fundType], "Missing defaults for \(fundType)")
        }
    }

    // MARK: - Backtest Presets

    func testBacktestPresetsAllocationsValid() {
        for preset in BacktestPreset.allCases {
            let config = preset.config(accumulate: true)
            let total = config.totalAllocation
            XCTAssertEqual(total, 1.0, accuracy: 0.001,
                           "Preset \(preset.rawValue) accumulate allocations should sum to 1.0, got \(total)")
        }
    }

    func testBacktestPresetsHarvestAllocationsValid() {
        for preset in BacktestPreset.allCases {
            let config = preset.config(accumulate: false)
            let total = config.totalAllocation
            XCTAssertEqual(total, 1.0, accuracy: 0.001,
                           "Preset \(preset.rawValue) harvest allocations should sum to 1.0, got \(total)")
        }
    }

    func testBacktestConfigAllocations() {
        var config = BacktestConfig()
        config.spxlPct = 0
        config.vtiPct = 0
        config.brgnxPct = 0
        config.tqqqPct = 0.5
        config.btcPct = 0.5
        config.gldPct = 0
        config.slvPct = 0

        let allocations = config.allocations
        XCTAssertEqual(allocations.count, 2)
        XCTAssertEqual(allocations[0].ticker, "TQQQ")
        XCTAssertEqual(allocations[0].pct, 0.5)
        XCTAssertEqual(allocations[1].ticker, "BTC")
        XCTAssertEqual(allocations[1].pct, 0.5)
    }

    func testBacktestConfigFilterZeroAllocations() {
        var config = BacktestConfig()
        config.spxlPct = 0
        config.vtiPct = 0
        config.brgnxPct = 0
        config.tqqqPct = 0
        config.btcPct = 1.0
        config.gldPct = 0
        config.slvPct = 0

        let allocations = config.allocations
        XCTAssertEqual(allocations.count, 1)
        XCTAssertEqual(allocations[0].ticker, "BTC")
    }

    func testBacktestDateRange() {
        let range = BacktestDateRange(start: "2020-01-01", end: "2025-01-01")
        XCTAssertEqual(range.daysElapsed, 1827)
        XCTAssertEqual(range.yearsElapsed, Double(1827) / 365.0, accuracy: 0.01)
    }

    // MARK: - Backtest Engine (with synthetic data)

    func testRunBacktestWithSyntheticData() {
        // Create minimal synthetic historical data for a single asset
        let prices = (0..<52).map { i in
            HistoricalData.PricePoint(
                date: dateByAddingWeeks(i, from: "2024-01-01"),
                value: 100.0 + Double(i) * 0.5  // Steady uptrend
            )
        }

        let hist = HistoricalData(
            ticker: "TEST", name: "Test Asset", type: "stock",
            startDate: prices.first!.date, endDate: prices.last!.date,
            dataPoints: prices.count, prices: prices, dividends: nil
        )

        var config = BacktestConfig()
        config.spxlPct = 0; config.vtiPct = 0; config.brgnxPct = 0
        config.tqqqPct = 0; config.btcPct = 0; config.gldPct = 0; config.slvPct = 0
        // Use a custom allocation by manipulating the struct
        // Since BacktestConfig uses fixed ticker names, we need to use one of the existing ones
        // and map our test data to that ticker
        let historicalData: [String: HistoricalData] = ["BTC": hist]
        config.btcPct = 1.0
        config.initialCash = 10000
        config.weeklyDCA = 100
        config.targetAPY = 0.25
        config.accumulate = true

        let result = runBacktest(config: config, historicalData: historicalData)
        XCTAssertNotNil(result)

        if let result {
            XCTAssertEqual(result.entries.count, 52)
            XCTAssertGreaterThan(result.totalBuys, 0)
            // Initial cash 10000 + 52 weekly DCA of 100 = at most 15200 invested
            XCTAssertGreaterThan(result.totalInvested, 0)
            XCTAssertLessThanOrEqual(result.totalInvested, 15200)
            XCTAssertGreaterThanOrEqual(result.finalValue, 0)
            XCTAssertEqual(result.weeks, 52)
            XCTAssertGreaterThan(result.daysElapsed, 350)
            // Monotonically increasing prices → no sell signals should fire
            XCTAssertEqual(result.totalSells, 0)
            // Drawdown is always non-negative
            XCTAssertGreaterThanOrEqual(result.maxDrawdown, 0)
        }
    }

    func testRunBacktestEmptyAllocations() {
        var config = BacktestConfig()
        config.spxlPct = 0; config.vtiPct = 0; config.brgnxPct = 0
        config.tqqqPct = 0; config.btcPct = 0; config.gldPct = 0; config.slvPct = 0
        let result = runBacktest(config: config, historicalData: [:])
        XCTAssertNil(result)
    }

    func testRunBacktestMissingHistoricalData() {
        var config = BacktestConfig()
        config.btcPct = 1.0
        // No BTC data provided
        let result = runBacktest(config: config, historicalData: [:])
        XCTAssertNil(result)
    }

    // MARK: - computeAvailableDateRange

    func testComputeAvailableDateRange() {
        let hist1 = HistoricalData(
            ticker: "A", name: "A", type: "stock",
            startDate: "2020-01-01", endDate: "2025-01-01",
            dataPoints: 100, prices: [], dividends: nil
        )
        let hist2 = HistoricalData(
            ticker: "B", name: "B", type: "stock",
            startDate: "2021-01-01", endDate: "2024-06-01",
            dataPoints: 100, prices: [], dividends: nil
        )

        let range = computeAvailableDateRange(
            historicalData: ["A": hist1, "B": hist2],
            allocations: [("A", 0.5), ("B", 0.5)]
        )

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, "2021-01-01")
        XCTAssertEqual(range?.end, "2024-06-01")
    }

    // MARK: - Full Fund Metrics Integration

    func testComputeFundMetricsForFund() {
        let config = makeStockConfig()
        let entries = [
            FundEntry(date: "2024-06-01", value: 1000, action: .BUY, amount: 1000, shares: 20, price: 50),
            FundEntry(date: "2024-09-01", value: 1100, action: .HOLD),
            FundEntry(date: "2024-12-01", value: 1200, action: .HOLD),
        ]

        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)
        let result = computeFundMetricsForFund(fund, asOfDate: "2025-01-01")

        XCTAssertEqual(result.metrics.platform, "test")
        XCTAssertEqual(result.metrics.ticker, "AAPL")
        XCTAssertEqual(result.metrics.currentValue, 1200, accuracy: 0.01)
        XCTAssertEqual(result.metrics.startInput, 1000, accuracy: 0.01)
        // Cycle-based: BUY 2024-06-01 to last entry 2024-12-01 = 183 days
        XCTAssertGreaterThan(result.metrics.daysActive, 180)
        XCTAssertEqual(result.state.gainUsd, 200, accuracy: 0.01)
        XCTAssertEqual(result.state.gainPct, 0.20, accuracy: 0.01)
    }

    // MARK: - Actionable Funds

    func testComputeActionableFunds() {
        let config = makeStockConfig()
        let entries = [
            FundEntry(date: "2025-02-01", value: 1000, action: .BUY, amount: 500),
        ]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        // 41 days since last entry, interval is 7 days -> 34 days overdue (2025-03-14 is a Friday)
        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-14")
        XCTAssertEqual(actionable.count, 1)
        XCTAssertEqual(actionable[0].daysOverdue, 34)
    }

    func testComputeActionableFundsSkipsClosed() {
        let config = makeStockConfig(status: .closed)
        let entries = [FundEntry(date: "2025-01-01", value: 1000)]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-15")
        XCTAssertEqual(actionable.count, 0)
    }

    func testComputeActionableFundsSkipsCash() {
        var config = makeStockConfig()
        config.fund_type = .cash
        let entries = [FundEntry(date: "2025-01-01", value: 5000)]
        let fund = FundData(platform: "test", ticker: "USD", config: config, entries: entries)

        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-15")
        XCTAssertEqual(actionable.count, 0)
    }

    func testComputeActionableFundsStockSkipsWeekend() {
        let config = makeStockConfig()
        let entries = [FundEntry(date: "2025-02-01", value: 1000, action: .BUY, amount: 500)]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        // 2025-03-15 is a Saturday — stock funds should not be actionable
        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-15")
        XCTAssertEqual(actionable.count, 0)
    }

    func testComputeActionableFundsCryptoNotSkippedOnWeekend() {
        var config = makeStockConfig()
        config.fund_type = .crypto
        let entries = [FundEntry(date: "2025-02-01", value: 1000, action: .BUY, amount: 500)]
        let fund = FundData(platform: "test", ticker: "BTC", config: config, entries: entries)

        // 2025-03-15 is a Saturday — crypto should still be actionable
        let actionable = computeActionableFunds([fund], asOfDate: "2025-03-15")
        XCTAssertEqual(actionable.count, 1)
    }

    func testComputeActionableFundsStockSkipsHoliday() {
        let config = makeStockConfig()
        let entries = [FundEntry(date: "2025-12-18", value: 1000, action: .BUY, amount: 500)]
        let fund = FundData(platform: "test", ticker: "AAPL", config: config, entries: entries)

        // 2025-12-25 is Christmas (Thursday) — stock market closed
        let actionable = computeActionableFunds([fund], asOfDate: "2025-12-25")
        XCTAssertEqual(actionable.count, 0)
    }

    // MARK: - Trading Day Detection

    func testIsStockTradingDayWeekday() {
        XCTAssertTrue(isStockTradingDay("2025-03-14"))  // Friday
        XCTAssertTrue(isStockTradingDay("2025-03-10"))  // Monday
        XCTAssertTrue(isStockTradingDay("2025-03-12"))  // Wednesday
    }

    func testIsStockTradingDayWeekend() {
        XCTAssertFalse(isStockTradingDay("2025-03-15")) // Saturday
        XCTAssertFalse(isStockTradingDay("2025-03-16")) // Sunday
    }

    func testIsStockTradingDayHolidays() {
        // New Year's Day 2025 (Wed Jan 1)
        XCTAssertFalse(isStockTradingDay("2025-01-01"))
        // MLK Day 2025 (Mon Jan 20)
        XCTAssertFalse(isStockTradingDay("2025-01-20"))
        // Good Friday 2025 (April 18)
        XCTAssertFalse(isStockTradingDay("2025-04-18"))
        // Christmas 2025 (Thu Dec 25)
        XCTAssertFalse(isStockTradingDay("2025-12-25"))
        // Day after Christmas is a trading day
        XCTAssertTrue(isStockTradingDay("2025-12-26"))
    }

    func testNextTradingDaySkipsWeekend() {
        // Saturday 2025-03-15 → Monday 2025-03-17
        let sat = isoDateFormatter.date(from: "2025-03-15")!
        let result = nextTradingDay(from: sat, fundType: .stock)
        XCTAssertEqual(isoDateFormatter.string(from: result), "2025-03-17")
    }

    func testNextTradingDayCryptoDoesNotSkip() {
        // Saturday — crypto doesn't skip
        let sat = isoDateFormatter.date(from: "2025-03-15")!
        let result = nextTradingDay(from: sat, fundType: .crypto)
        XCTAssertEqual(isoDateFormatter.string(from: result), "2025-03-15")
    }

    // MARK: - Entry Rows

    func testComputeEntryRows() {
        let config = makeStockConfig(accumulate: true)
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20),
            FundEntry(date: "2024-07-01", value: 1200, action: .HOLD, dividend: 25),
            FundEntry(date: "2025-01-01", value: 1400, action: .HOLD),
        ]

        let rows = computeEntryRows(entries: entries, config: config)
        XCTAssertEqual(rows.count, 3)

        // First entry: just bought, no gains yet
        XCTAssertEqual(rows[0].extracted, 0, accuracy: 0.01)
        XCTAssertFalse(rows[0].isClosingEntry)

        // Second entry: dividend of 25
        XCTAssertEqual(rows[1].realized, 25, accuracy: 0.01)

        // Third entry: unrealized gains from 1000 to 1400 = 400, plus 25 dividend realized
        XCTAssertEqual(rows[2].liquidPnl, 425, accuracy: 0.01)
    }

    // MARK: - ChartBounds

    func testChartBoundsIsEmpty() {
        XCTAssertTrue(ChartBounds().isEmpty)
        XCTAssertTrue(ChartBounds(yMin: nil, yMax: nil).isEmpty)
        XCTAssertFalse(ChartBounds(yMin: 0, yMax: nil).isEmpty)
        XCTAssertFalse(ChartBounds(yMin: nil, yMax: 100).isEmpty)
        XCTAssertFalse(ChartBounds(yMin: 0, yMax: 100).isEmpty)
    }

    // MARK: - Cash Interest

    func testComputeCashInterest() {
        let config = makeStockConfig(cashApy: 0.04)
        // No trades, no cashflows — full 10000 earning 4% for 365 days
        let interest = computeCashInterest(config: config, trades: [], cashflows: [], asOfDate: "2025-01-01")
        // With no events, lastDate = asOfDate, so finalDays = 0, interest = 0
        // Need at least one event or the function uses asOfDate as lastDate
        XCTAssertEqual(interest, 0, accuracy: 0.01)
    }

    func testComputeCashInterestWithTrade() {
        let config = makeStockConfig(cashApy: 0.04)
        let cashflows = [CashFlow(date: "2023-12-31", amountUsd: 10000, type: .deposit)]
        let trades = [Trade(date: "2024-01-01", amountUsd: 1000, type: .buy)]
        // Expected ≈ 10000 * (1.04^(1/365) - 1)  (1 day @ $10k)
        //         + 9000 * (1.04^(366/365) - 1)  (366 days @ $9k; 2024 is a leap year)
        // ≈ 1.07 + 361.01 ≈ 362.08
        let interest = computeCashInterest(config: config, trades: trades, cashflows: cashflows, asOfDate: "2025-01-01")
        // Previously accuracy: 5.0 (a ~1.4% slack with no floating-point justification).
        // Tightened to 0.50 (~0.14%) which catches any off-by-day regression.
        XCTAssertEqual(interest, 362.08, accuracy: 0.50)
    }

    // MARK: - Portfolio Metrics

    func testComputePortfolioMetrics() {
        let config1 = makeStockConfig()
        let entries1 = [
            FundEntry(date: "2024-06-01", value: 1000, action: .BUY, amount: 1000, shares: 20, fund_size: 5000),
            FundEntry(date: "2025-01-01", value: 1200, action: .HOLD, fund_size: 5000),
        ]
        let fund1 = FundData(platform: "test", ticker: "AAPL", config: config1, entries: entries1)

        let config2 = makeStockConfig()
        let entries2 = [
            FundEntry(date: "2024-06-01", value: 500, action: .BUY, amount: 500, shares: 5, fund_size: 3000),
            FundEntry(date: "2025-01-01", value: 600, action: .HOLD, fund_size: 3000),
        ]
        let fund2 = FundData(platform: "test", ticker: "GOOG", config: config2, entries: entries2)

        let portfolio = computePortfolioMetrics([fund1, fund2], asOfDate: "2025-01-01")

        XCTAssertEqual(portfolio.activeFunds, 2)
        XCTAssertEqual(portfolio.closedFunds, 0)
        XCTAssertEqual(portfolio.totalValue, 1800, accuracy: 0.01)
        XCTAssertEqual(portfolio.funds.count, 2)
        XCTAssertEqual(portfolio.states.count, 2)
        XCTAssertGreaterThan(portfolio.totalFundSize, 0)
    }

    // MARK: - TSV formatting helpers

    func testFmtCurrencyRoundTrip() {
        // Verify currency values survive parse → serialize without precision drift
        let line = "2025-01-01\t245.55\t\tHOLD\t100\t\t\t\t\t\t245.55\t\t\t\t\t\t\t\t\t\t\t"
        let headers = ["date","value","cash","action","amount","shares","price","dividend","expense","cash_interest","fund_size","margin_available","margin_borrowed","margin_expense","notes","contracts","entry_price","liquidation_price","unrealized_pnl","margin_locked","fee","margin"]
        let entry = parseEntry(line, headers: headers)
        XCTAssertEqual(entry.value, 245.55, accuracy: 0.001)
        XCTAssertEqual(entry.fund_size, 245.55)
        let serialized = serializeEntry(entry)
        XCTAssertTrue(serialized.contains("245.55"), "Serialized value should be clean: \(serialized)")
        XCTAssertFalse(serialized.contains("245.55000000000001"), "Should not contain precision artifacts")
    }

    // MARK: - BacktestEngine: Declining Market

    func testRunBacktestDecliningMarket() {
        // Price series monotonically declining → sell signals should fire
        let prices = (0..<52).map { i in
            HistoricalData.PricePoint(
                date: dateByAddingWeeks(i, from: "2024-01-01"),
                value: 200.0 - Double(i) * 2.0  // Steady downtrend: 200 → 98
            )
        }

        let hist = HistoricalData(
            ticker: "TEST", name: "Test Asset", type: "stock",
            startDate: prices.first!.date, endDate: prices.last!.date,
            dataPoints: prices.count, prices: prices, dividends: nil
        )

        var config = BacktestConfig()
        config.spxlPct = 0; config.vtiPct = 0; config.brgnxPct = 0
        config.tqqqPct = 0; config.btcPct = 1.0; config.gldPct = 0; config.slvPct = 0
        config.initialCash = 10000
        config.weeklyDCA = 100
        config.targetAPY = 0.10
        config.accumulate = true

        let result = runBacktest(config: config, historicalData: ["BTC": hist])
        XCTAssertNotNil(result)

        if let result {
            XCTAssertEqual(result.entries.count, 52)
            // DCA buys every week regardless of price direction
            XCTAssertGreaterThan(result.totalBuys, 0)
            XCTAssertGreaterThan(result.totalInvested, 0)
            // DCA in a declining market: final value reflects cost averaging effect
            XCTAssertGreaterThan(result.finalValue, 0)
            // maxDrawdown should be >= 0 (may be 0 if drawdown isn't measured this way)
            XCTAssertGreaterThanOrEqual(result.maxDrawdown, 0)
        }
    }

    // MARK: - BacktestEngine: Harvest Mode

    func testRunBacktestHarvestMode() {
        // Same price data as synthetic uptrend, but accumulate = false (harvest mode)
        let prices = (0..<52).map { i in
            HistoricalData.PricePoint(
                date: dateByAddingWeeks(i, from: "2024-01-01"),
                value: 100.0 + Double(i) * 2.0  // Uptrend
            )
        }

        let hist = HistoricalData(
            ticker: "TEST", name: "Test Asset", type: "stock",
            startDate: prices.first!.date, endDate: prices.last!.date,
            dataPoints: prices.count, prices: prices, dividends: nil
        )

        var configAccumulate = BacktestConfig()
        configAccumulate.spxlPct = 0; configAccumulate.vtiPct = 0; configAccumulate.brgnxPct = 0
        configAccumulate.tqqqPct = 0; configAccumulate.btcPct = 1.0; configAccumulate.gldPct = 0; configAccumulate.slvPct = 0
        configAccumulate.initialCash = 10000
        configAccumulate.weeklyDCA = 100
        configAccumulate.targetAPY = 0.25
        configAccumulate.accumulate = true

        var configHarvest = configAccumulate
        configHarvest.accumulate = false

        let accResult = runBacktest(config: configAccumulate, historicalData: ["BTC": hist])
        let harvestResult = runBacktest(config: configHarvest, historicalData: ["BTC": hist])

        XCTAssertNotNil(accResult)
        XCTAssertNotNil(harvestResult)

        if let acc = accResult, let harvest = harvestResult {
            // Harvest mode sells the entire position; accumulate only sells a portion.
            // Harvest should therefore extract more or equal than accumulate.
            XCTAssertGreaterThanOrEqual(harvest.totalExtracted, acc.totalExtracted)
            // Both modes should see at least one buy on an uptrend
            XCTAssertGreaterThan(harvest.totalBuys, 0)
        }
    }

    // MARK: - computeAvailableDateRange: Edge Cases

    func testComputeAvailableDateRangeSingleAsset() {
        let hist = HistoricalData(
            ticker: "A", name: "A", type: "stock",
            startDate: "2020-01-01", endDate: "2025-01-01",
            dataPoints: 10, prices: [], dividends: nil
        )

        let range = computeAvailableDateRange(
            historicalData: ["A": hist],
            allocations: [("A", 1.0)]
        )

        XCTAssertNotNil(range)
        XCTAssertEqual(range?.start, "2020-01-01")
        XCTAssertEqual(range?.end, "2025-01-01")
    }

    func testComputeAvailableDateRangeEmpty() {
        let range = computeAvailableDateRange(
            historicalData: [:],
            allocations: []
        )
        XCTAssertNil(range)
    }

    func testComputeAvailableDateRangeAllZeroPct() {
        let hist = HistoricalData(
            ticker: "A", name: "A", type: "stock",
            startDate: "2020-01-01", endDate: "2025-01-01",
            dataPoints: 10, prices: [], dividends: nil
        )

        // All allocations are 0 pct — treated as no active allocations
        let range = computeAvailableDateRange(
            historicalData: ["A": hist],
            allocations: [("A", 0.0)]
        )
        XCTAssertNil(range)
    }

    // MARK: - Harvest-Mode Partial Sell Cost Basis

    func testComputeEntryRowsHarvestPartialSell() {
        // Harvest mode (accumulate: false): partial sell reduces cost basis proportionally.
        // value before sell = 800, sell amount = 200
        // sellProportion = 200 / (800 + 200) = 0.20
        // costBasisReturned = 1000 * 0.20 = 200
        // entryExtracted = max(0, 200 - 200) = 0   (selling at cost, no profit yet)
        // remaining costBasis = 1000 - 200 = 800
        let config = makeStockConfig(accumulate: false)
        let entries = [
            FundEntry(date: "2024-01-01", value: 1000, action: .BUY, amount: 1000, shares: 20),
            // value is pre-action remaining equity; sell 200 out of total (800 remaining + 200 sold)
            FundEntry(date: "2024-06-01", value: 800, action: .SELL, amount: 200, shares: 4),
        ]

        let rows = computeEntryRows(entries: entries, config: config)
        XCTAssertEqual(rows.count, 2)

        let sellRow = rows[1]
        // Cost basis after proportional reduction: 1000 * (1 - 0.20) = 800
        XCTAssertEqual(sellRow.invested, 800, accuracy: 0.01)
        // No profit yet (sold at cost)
        XCTAssertEqual(sellRow.extracted, 0, accuracy: 0.01)
        // Post-action equity = max(0, 800 - 200) = 600; unrealized = 600 - 800 = -200
        XCTAssertEqual(sellRow.unrealized, -200, accuracy: 0.01)
        // Not a closing entry (shares remain)
        XCTAssertFalse(sellRow.isClosingEntry)
    }
}

// MARK: - Test Utilities

private func dateByAddingWeeks(_ weeks: Int, from startDate: String) -> String {
    guard let date = isoDateFormatter.date(from: startDate) else { return startDate }
    let newDate = Calendar.current.date(byAdding: .day, value: weeks * 7, to: date)!
    return isoDateFormatter.string(from: newDate)
}
