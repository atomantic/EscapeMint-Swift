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

struct BacktestConfig {
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

    // DCA Tiers
    var inputMin: Double = 100
    var inputMid: Double = 100
    var inputMax: Double = 100
    var maxAtPct: Double = -0.25

    // Optional
    var marginAccessUSD: Double = 0
    var marginAPR: Double = 0
    var cashAPY: Double = 0.044

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
    let finalValue: Double
    let totalInvested: Double
    let totalGain: Double
    let gainPct: Double
    let apy: Double
    let maxDrawdown: Double
    let weeks: Int

    struct BacktestEntry {
        let date: String
        let equity: Double
        let cash: Double
        let totalValue: Double
        let costBasis: Double
        let action: FundAction?
        let amount: Double?
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

    var config: BacktestConfig {
        switch self {
        case .blend:
            return BacktestConfig()
        case .tqqq:
            var c = BacktestConfig(); c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 1.0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.20; return c
        case .spxl:
            var c = BacktestConfig(); c.spxlPct = 1.0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.10; return c
        case .vti:
            var c = BacktestConfig(); c.spxlPct = 0; c.vtiPct = 1.0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.10; return c
        case .brgnx:
            var c = BacktestConfig(); c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 1.0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.10; return c
        case .btc:
            var c = BacktestConfig(); c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 1.0; c.gldPct = 0; c.slvPct = 0
            c.targetAPY = 0.30; return c
        case .gld:
            var c = BacktestConfig(); c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 1.0; c.slvPct = 0
            c.targetAPY = 0.08; return c
        case .slv:
            var c = BacktestConfig(); c.spxlPct = 0; c.vtiPct = 0; c.brgnxPct = 0
            c.tqqqPct = 0; c.btcPct = 0; c.gldPct = 0; c.slvPct = 1.0
            c.targetAPY = 0.10; return c
        }
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

// MARK: - Backtest Runner

func runBacktest(config: BacktestConfig, historicalData: [String: HistoricalData]) -> BacktestResult? {
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
    guard let dates = commonDates?.sorted(), dates.count >= 2 else { return nil }

    // Build price lookup dictionaries for O(1) access
    var priceLookups: [String: [String: Double]] = [:]
    for (ticker, _) in allocations {
        guard let hist = historicalData[ticker] else { return nil }
        priceLookups[ticker] = Dictionary(uniqueKeysWithValues: hist.prices.map { ($0.date, $0.value) })
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
    var totalInvested = config.initialCash
    var costBasis = 0.0
    var peak = config.initialCash
    var maxDrawdown = 0.0
    var entries: [BacktestResult.BacktestEntry] = []

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
        accumulate: config.accumulate
    )

    for (i, pp) in blendedPrices.enumerated() {
        let price = pp.price
        let equity = shares * price

        // Cash interest (weekly)
        cash += cash * (config.cashAPY / 52.0)

        // Add weekly DCA to cash (after first week)
        if i > 0 {
            cash += config.weeklyDCA
            totalInvested += config.weeklyDCA
        }

        // Compute state for recommendation
        let gainUsd = costBasis > 0 ? equity - costBasis : 0
        let gainPct = costBasis > 0 ? (equity / costBasis) - 1.0 : 0
        let expectedTarget = costBasis * (1.0 + config.targetAPY * Double(i) * 7.0 / 365.0)
        let targetDiff = equity - expectedTarget

        let state = FundState(
            cashAvailableUsd: cash,
            expectedTargetUsd: expectedTarget,
            actualValueUsd: equity,
            startInputUsd: costBasis,
            gainUsd: gainUsd,
            gainPct: gainPct,
            targetDiffUsd: targetDiff,
            cashInterestUsd: 0,
            realizedGainsUsd: 0
        )

        let rec = computeRecommendation(config: fundConfig, state: state)
        var action: FundAction?
        var amount: Double?

        if let rec {
            if rec.action == .BUY && rec.amount > 0 && cash >= rec.amount {
                let buyAmount = min(rec.amount, cash)
                let buyShares = buyAmount / price
                shares += buyShares
                cash -= buyAmount
                costBasis += buyAmount
                action = .BUY
                amount = buyAmount
            } else if rec.action == .SELL && rec.amount > 0 && shares > 0 {
                let sellAmount = min(rec.amount, equity)
                let sellShares = sellAmount / price
                shares -= sellShares
                cash += sellAmount
                let sellFraction = costBasis > 0 ? sellAmount / equity : 1.0
                costBasis = max(0, costBasis * (1.0 - sellFraction))
                action = .SELL
                amount = sellAmount
            }
        }

        let newTotal = shares * price + cash
        peak = max(peak, newTotal)
        if peak > 0 {
            let drawdown = (peak - newTotal) / peak
            maxDrawdown = max(maxDrawdown, drawdown)
        }

        entries.append(BacktestResult.BacktestEntry(
            date: pp.date, equity: shares * price, cash: cash,
            totalValue: newTotal, costBasis: costBasis,
            action: action, amount: amount
        ))
    }

    let finalValue = entries.last?.totalValue ?? config.initialCash
    let totalGain = finalValue - totalInvested
    let gainPct = totalInvested > 0 ? totalGain / totalInvested : 0
    let weeks = entries.count
    let days = weeks * 7
    let apy = days > 0 ? (totalGain / totalInvested) * (365.0 / Double(days)) : 0

    return BacktestResult(
        entries: entries, finalValue: finalValue,
        totalInvested: totalInvested, totalGain: totalGain,
        gainPct: gainPct, apy: apy,
        maxDrawdown: maxDrawdown, weeks: weeks
    )
}
