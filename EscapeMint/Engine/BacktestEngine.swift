import Foundation

// MARK: - Backtest Types

struct HistoricalData: Codable {
    let ticker: String
    let name: String
    let type: String
    let startDate: String
    let endDate: String
    let dataPoints: Int
    let prices: [PricePoint]
    let dividends: [DividendPoint]?

    struct PricePoint: Codable {
        let date: String
        let value: Double
    }

    struct DividendPoint: Codable {
        let exDate: String
        let amount: Double
    }
}

struct BacktestConfig: Equatable {
    // Allocation percentages (must sum to 1.0)
    var spxlPct: Double = 0
    var vtiPct: Double = 0.05
    var brgnxPct: Double = 0
    var tqqqPct: Double = 0.15
    var btcPct: Double = 0.70
    var gldPct: Double = 0.05
    var slvPct: Double = 0.05

    // DCA Strategy
    var initialCash: Double = 10000
    var weeklyDCA: Double = 100
    var targetAPY: Double = 0.25
    var minProfitUSD: Double = 1000
    var accumulate: Bool = true
    var reinvest: Bool = true

    // DCA Tiers
    var inputMin: Double = 100
    var inputMid: Double = 100
    var inputMax: Double = 100
    var maxAtPct: Double = -0.25

    // Optional
    var marginAccessUSD: Double = 0
    var marginAPR: Double = 0.05
    var cashAPY: Double = 0.04

    var totalAllocation: Double {
        spxlPct + vtiPct + brgnxPct + tqqqPct + btcPct + gldPct + slvPct
    }

    var allocations: [(ticker: String, pct: Double)] {
        [
            ("SPXL", spxlPct), ("VTI", vtiPct), ("BRGNX", brgnxPct),
            ("TQQQ", tqqqPct), ("BTC", btcPct), ("GLD", gldPct), ("SLV", slvPct)
        ].filter { $0.pct > 0 }
    }
}

struct BacktestResult {
    let entries: [BacktestEntry]
    let trades: [TradeRecord]
    let finalValue: Double
    let totalInvested: Double
    let totalExtracted: Double
    let liquidAPY: Double
    let realizedAPY: Double
    let unrealizedGain: Double
    let realizedGain: Double
    let liquidGain: Double
    let totalBuys: Int
    let totalSells: Int
    let maxDrawdown: Double
    let daysElapsed: Int
    let sumDividends: Double
    let sumCashInterest: Double

    // Legacy convenience
    var totalGain: Double { liquidGain }
    var gainPct: Double { totalInvested > 0 ? liquidGain / totalInvested : 0 }
    var apy: Double { liquidAPY }
    var weeks: Int { entries.count }

    struct BacktestEntry: Identifiable {
        let id = UUID()
        let date: String
        let equity: Double
        let cash: Double
        let fundSize: Double
        let invested: Double
        let totalInvested: Double
        let totalExtracted: Double
        let expectedTarget: Double
        let action: FundAction?
        let amount: Double
        let cashInterest: Double
        let sumCashInterest: Double
        let dividend: Double
        let sumDividends: Double

        // Convenience - matches web app's computed fields
        var unrealized: Double { equity - max(0, invested) }
        var realized: Double { sumCashInterest + sumDividends + totalExtracted }
        var liquidPnL: Double { realized + unrealized }
        // dateValue provided by DateIdentifiable protocol extension
    }

    struct TradeRecord {
        let date: String
        let action: FundAction
        let amount: Double
        let equity: Double
        let price: Double
        let reason: String
    }
}

// MARK: - Presets

enum BacktestPreset: String, CaseIterable, Identifiable {
    case blend = "Blend"
    case tqqq = "TQQQ"
    case spxl = "SPXL"
    case vti = "VTI"
    case brgnx = "BRGNX"
    case btc = "BTC"
    case gld = "GLD"
    case slv = "SLV"

    var id: String { rawValue }

    func config(accumulate: Bool) -> BacktestConfig {
        var c = BacktestConfig()
        c.accumulate = accumulate

        switch self {
        case .blend:
            // Blend uses base defaults; harvest overrides match web's getDefaultConfig
            if !accumulate {
                c.targetAPY = 0.40
                c.inputMid = 200
                c.inputMax = 250
            }
        case .tqqq:
            c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 1.0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = accumulate ? 0.20 : 0.52
            if !accumulate { c.inputMax = 350 }
        case .spxl:
            c.spxlPct = 1.0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.10
            if !accumulate { c.inputMax = 200 }
        case .vti:
            c.spxlPct = 0; c.vtiPct = 1.0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.10
            if !accumulate { c.inputMax = 150 }
        case .brgnx:
            c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 1.0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.10
            if !accumulate { c.inputMax = 150 }
        case .btc:
            c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 1.0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = accumulate ? 0.30 : 0.80
            if !accumulate { c.inputMax = 200 }
        case .gld:
            c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 1.0; c.slvPct = 0
            c.targetAPY = 0.08
            if !accumulate { c.inputMax = 150 }
        case .slv:
            c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 1.0
            c.targetAPY = 0.10
            if !accumulate { c.inputMax = 150 }
        }

        return c
    }

    // Legacy compatibility
    var config: BacktestConfig { config(accumulate: true) }
}

// MARK: - Date Range

struct BacktestDateRange: Equatable {
    var start: String
    var end: String

    var daysElapsed: Int {
        daysBetween(start, end)
    }

    var yearsElapsed: Double {
        Double(daysElapsed) / 365.0
    }
}

// MARK: - Historical Data Loading

func loadHistoricalData() -> [String: HistoricalData] {
    let tickers = ["btc", "tqqq", "spxl", "vti", "brgnx", "gld", "slv"]
    var result: [String: HistoricalData] = [:]
    for ticker in tickers {
        guard let url = Bundle.main.url(forResource: "\(ticker)-weekly", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let hist = try? JSONDecoder().decode(HistoricalData.self, from: data) else {
            continue
        }
        result[ticker.uppercased()] = hist
    }
    return result
}

func computeAvailableDateRange(historicalData: [String: HistoricalData], allocations: [(ticker: String, pct: Double)]) -> BacktestDateRange? {
    var latestStart: String?
    var earliestEnd: String?

    for (ticker, pct) in allocations where pct > 0 {
        guard let hist = historicalData[ticker] else { continue }
        if let ls = latestStart {
            if hist.startDate > ls { latestStart = hist.startDate }
        } else {
            latestStart = hist.startDate
        }
        if let ee = earliestEnd {
            if hist.endDate < ee { earliestEnd = hist.endDate }
        } else {
            earliestEnd = hist.endDate
        }
    }

    guard let start = latestStart, let end = earliestEnd, start < end else { return nil }
    return BacktestDateRange(start: start, end: end)
}

// MARK: - Backtest Runner

func runBacktest(config: BacktestConfig, historicalData: [String: HistoricalData], dateRange: BacktestDateRange? = nil) -> BacktestResult? {
    let allocations = config.allocations
    guard !allocations.isEmpty else { return nil }

    // Find common date range
    var commonDates: [String]?
    for (ticker, pct) in allocations where pct > 0 {
        guard let hist = historicalData[ticker] else { return nil }
        let dates = hist.prices.map(\.date)
        if let existing = commonDates {
            let dateSet = Set(dates)
            commonDates = existing.filter { dateSet.contains($0) }
        } else {
            commonDates = dates
        }
    }
    guard var dates = commonDates?.sorted(), dates.count >= 2 else { return nil }

    // Apply date range filter
    if let range = dateRange {
        dates = dates.filter { $0 >= range.start && $0 <= range.end }
        guard dates.count >= 2 else { return nil }
    }

    // Build price lookup dictionaries for O(1) access
    var priceLookups: [String: [String: Double]] = [:]
    for (ticker, _) in allocations {
        guard let hist = historicalData[ticker] else { return nil }
        priceLookups[ticker] = Dictionary(uniqueKeysWithValues: hist.prices.map { ($0.date, $0.value) })
    }

    // Build dividend lookup
    var dividendLookups: [String: [HistoricalData.DividendPoint]] = [:]
    for (ticker, _) in allocations {
        guard let hist = historicalData[ticker] else { continue }
        dividendLookups[ticker] = hist.dividends ?? []
    }

    // Build blended price series (normalized to 100 at start)
    var basePrices: [String: Double] = [:]
    for (ticker, _) in allocations {
        guard let firstPrice = priceLookups[ticker]?[dates[0]] else { return nil }
        basePrices[ticker] = firstPrice
    }

    var blendedPrices: [(date: String, price: Double)] = []
    for date in dates {
        var blended = 0.0
        for (ticker, pct) in allocations {
            guard let base = basePrices[ticker],
                  let priceValue = priceLookups[ticker]?[date] else { continue }
            let normalized = (priceValue / base) * 100.0
            blended += normalized * pct
        }
        blendedPrices.append((date, blended))
    }

    // Run DCA simulation
    var cash = config.initialCash
    var shares = 0.0
    var totalInvested = 0.0
    var totalExtracted = 0.0
    var costBasis = 0.0
    var sumCashInterest = 0.0
    var sumDividends = 0.0
    var entries: [BacktestResult.BacktestEntry] = []
    var trades: [BacktestResult.TradeRecord] = []

    // Equivalent shares for dividend tracking
    var equivShares: [String: Double] = [:]
    for (ticker, _) in allocations {
        equivShares[ticker] = 0
    }

    let weeklyInterestRate = config.cashAPY / 52.0

    let fundConfig = FundConfig(
        fund_type: .stock, status: .active,
        fund_size_usd: config.initialCash,
        target_apy: config.targetAPY,
        interval_days: 7,
        input_min_usd: config.inputMin,
        input_mid_usd: config.inputMid,
        input_max_usd: config.inputMax,
        max_at_pct: config.maxAtPct,
        min_profit_usd: config.minProfitUSD,
        cash_apy: config.cashAPY,
        manage_cash: true,
        accumulate: config.accumulate,
        dividend_reinvest: false,
        interest_reinvest: false,
        expense_from_fund: false
    )

    // Incremental state for O(n) expected target computation (avoids O(n²))
    var startInput = 0.0
    var expectedGain = 0.0
    var incTotalBuys = 0.0

    for (i, pp) in blendedPrices.enumerated() {
        let price = pp.price
        let equity = shares * price

        // Cash interest (weekly, skip first week)
        let weeklyInterest = i > 0 ? cash * weeklyInterestRate : 0
        sumCashInterest += weeklyInterest
        cash += weeklyInterest

        // Dividend collection
        var weeklyDividend = 0.0
        if i > 0 {
            let prevDate = blendedPrices[i - 1].date
            for (ticker, _) in allocations {
                let eqShares = equivShares[ticker] ?? 0
                guard eqShares > 0 else { continue }
                let divs = dividendLookups[ticker] ?? []
                for div in divs where div.exDate > prevDate && div.exDate <= pp.date {
                    weeklyDividend += eqShares * div.amount
                }
            }
            cash += weeklyDividend
            sumDividends += weeklyDividend
        }

        // Incremental expected target (O(1) per iteration instead of O(n))
        let expectedTarget = startInput + expectedGain
        let gainUsd = costBasis > 0 ? equity - costBasis : 0.0
        let rawGainPct = costBasis > 0 ? (equity / costBasis) - 1.0 : 0.0
        let gainPct = rawGainPct.isFinite ? rawGainPct : 0.0
        let targetDiff = equity - expectedTarget

        let cashAvailable = config.reinvest ? cash : max(0, (config.initialCash + cash - totalInvested) - costBasis)

        let state = FundState(
            cashAvailableUsd: cashAvailable,
            expectedTargetUsd: expectedTarget,
            actualValueUsd: equity,
            startInputUsd: costBasis,
            gainUsd: gainUsd,
            gainPct: gainPct,
            targetDiffUsd: targetDiff,
            cashInterestUsd: sumCashInterest,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: fundConfig, state: state)
        var action: FundAction?
        var amount = 0.0

        if let rec, rec.action != .HOLD, rec.amount > 0 {
            if rec.action == .BUY && cash >= rec.amount {
                let buyAmount = min(rec.amount, cash)
                let buyShares = buyAmount / price
                shares += buyShares
                cash -= buyAmount
                totalInvested += buyAmount
                costBasis += buyAmount

                // Track equivalent shares per asset for dividends
                for (ticker, pct) in allocations {
                    guard let basePrice = basePrices[ticker], basePrice > 0 else { continue }
                    equivShares[ticker] = (equivShares[ticker] ?? 0) + (buyAmount * pct) / basePrice
                }

                // Incremental expected target: add this buy's future expected gain
                incTotalBuys += buyAmount
                startInput += buyAmount
                let tradeDays = daysBetween(pp.date, dates.last ?? pp.date)
                if tradeDays > 0 {
                    expectedGain += buyAmount * (pow(1.0 + config.targetAPY, Double(tradeDays) / 365.0) - 1.0)
                }

                action = .BUY
                amount = buyAmount

                trades.append(.init(date: pp.date, action: .BUY, amount: buyAmount,
                                    equity: equity, price: price, reason: rec.reasoning))
            } else if rec.action == .SELL && shares > 0 {
                let sellAmount: Double
                if config.accumulate {
                    sellAmount = min(rec.amount, equity)
                } else {
                    sellAmount = equity
                }

                let sellShares = sellAmount / price
                let sellProportion = shares > 0 ? sellShares / shares : 1.0
                shares = max(0, shares - sellShares)
                cash += sellAmount
                totalExtracted += sellAmount

                // Reduce equivalent shares proportionally
                for (ticker, _) in allocations {
                    equivShares[ticker] = (equivShares[ticker] ?? 0) * (1 - sellProportion)
                }

                // Liquidation detection
                let sharesLiquidated = shares < 0.0001
                let valueLiquidated = equity <= sellAmount + 0.01
                let dollarsLiquidated = totalExtracted >= totalInvested
                let isFullLiquidation = sharesLiquidated || valueLiquidated || dollarsLiquidated

                if isFullLiquidation {
                    costBasis = 0
                    shares = 0
                    startInput = 0
                    expectedGain = 0
                    incTotalBuys = 0
                    for (ticker, _) in allocations {
                        equivShares[ticker] = 0
                    }
                } else if !config.accumulate {
                    let sf = sellProportion
                    costBasis = costBasis * (1 - sf)
                    expectedGain *= (1 - sf)
                    startInput = max(0, startInput * (1 - sf))
                }

                action = .SELL
                amount = sellAmount

                trades.append(.init(date: pp.date, action: .SELL, amount: sellAmount,
                                    equity: equity, price: price, reason: rec.reasoning))
            }
        }

        let currentEquity = shares * price
        let fundSize = cash + costBasis

        entries.append(BacktestResult.BacktestEntry(
            date: pp.date,
            equity: currentEquity,
            cash: cash,
            fundSize: fundSize,
            invested: costBasis,
            totalInvested: totalInvested,
            totalExtracted: totalExtracted,
            expectedTarget: state.expectedTargetUsd,
            action: action,
            amount: amount,
            cashInterest: weeklyInterest,
            sumCashInterest: sumCashInterest,
            dividend: weeklyDividend,
            sumDividends: sumDividends
        ))
    }

    let finalEquity = entries.last.map { $0.equity } ?? 0
    let finalValue = (entries.last?.cash ?? cash) + finalEquity
    let daysElapsed = dates.count >= 2 ? daysBetween(dates[0], dates[dates.count - 1]) : 0

    let unrealizedGain = finalEquity - costBasis
    let soldCostBasis = totalInvested - costBasis
    let realizedGain = (totalExtracted - soldCostBasis) + sumCashInterest + sumDividends
    let liquidGain = finalValue - config.initialCash

    let realizedAPY = daysElapsed > 0 && config.initialCash > 0
        ? (realizedGain / config.initialCash) * (365.0 / Double(daysElapsed)) : 0
    let liquidAPY = daysElapsed > 0 && config.initialCash > 0
        ? (liquidGain / config.initialCash) * (365.0 / Double(daysElapsed)) : 0

    let totalBuys = trades.filter { $0.action == .BUY }.count
    let totalSells = trades.filter { $0.action == .SELL }.count

    // Compute max drawdown from time series
    var peak = 0.0
    var maxDrawdown = 0.0
    for entry in entries {
        peak = max(peak, entry.fundSize)
        if peak > 0 {
            let drawdown = (peak - entry.fundSize) / peak
            maxDrawdown = max(maxDrawdown, drawdown)
        }
    }

    return BacktestResult(
        entries: entries, trades: trades,
        finalValue: finalValue,
        totalInvested: totalInvested,
        totalExtracted: totalExtracted,
        liquidAPY: liquidAPY,
        realizedAPY: realizedAPY,
        unrealizedGain: unrealizedGain,
        realizedGain: realizedGain,
        liquidGain: liquidGain,
        totalBuys: totalBuys,
        totalSells: totalSells,
        maxDrawdown: maxDrawdown,
        daysElapsed: daysElapsed,
        sumDividends: sumDividends,
        sumCashInterest: sumCashInterest
    )
}
