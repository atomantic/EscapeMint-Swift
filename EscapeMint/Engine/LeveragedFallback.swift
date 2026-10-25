import Foundation

// MARK: - 1x fallback for daily-reset leveraged funds
//
// A 3x fund resets every day. The loss that has ruined these products is a slow bear
// market: volatility decay can take a 3x fund down more than 99% (2000–02), and the
// issuer may close it or reverse-split it. A one-day index drop of about 33% would
// zero the fund. That is a stress test. Since 1975 the S&P 500's worst day was
// −20.5% (Oct 19, 1987); the Nasdaq-100's worst day since 1985 was about −15% that
// same session.
//
// This rule is off unless a fund turns it on. When it is on, a new buy goes to the 1x
// equivalent (TQQQ→QQQ, SOXL→SOXX, SPXL→SPY) while the 3x price is down past the
// threshold from its peak in the current trend, or the underlying is below its moving
// average. Buys return to the 3x fund when the underlying closes back above that average,
// which starts a new trend peak. Shares already held are not sold. The rule never borrows.

enum LeveragedPairs {
    /// 3x ticker → 1x ticker the next buy should use.
    static let underlyingByTicker: [String: String] = [
        "tqqq": "qqq",
        "soxl": "soxx",
        "spxl": "spy",
    ]

    static func suggestedUnderlying(for ticker: String) -> String? {
        underlyingByTicker[ticker.lowercased()]
    }
}

enum PriceCadence {
    case daily
    case weekly
}

/// Weekly bundled prices stand in for a daily average: 200 days ≈ 40 weeks.
func fallbackMovingAverageBars(days: Int, cadence: PriceCadence) -> Int {
    let span = max(1, days)
    switch cadence {
    case .daily: return span
    case .weekly: return max(1, span / 5)
    }
}

struct FallbackRule: Equatable {
    var enabled: Bool = false
    /// Positive fraction. 0.60 means "down 60%".
    var drawdownThreshold: Double = 0.60
    /// Number of closes in the moving average, in the same cadence as the price arrays.
    var movingAverageBars: Int = 200
}

enum FallbackRoute: Equatable {
    case leveraged
    case underlying
}

struct FallbackRoutePoint: Equatable {
    var drawdown: Double
    var belowMovingAverage: Bool
    var movingAverage: Double?
    var route: FallbackRoute
}

struct FallbackContext {
    var routeTicker: String
    var leveragedPrices: [Double]
    var underlyingCloses: [Double]
    var movingAverageBars: Int
    var costBasisDrawdown: Double?
}

struct FallbackDecision: Equatable {
    var route: FallbackRoute
    var priceDrawdown: Double
    var belowMovingAverage: Bool
    var movingAverage: Double?
}

// MARK: - Route

/// Moving average of `values[endIndex - length + 1 ... endIndex]`, summing oldest first.
func trailingMovingAverage(_ values: [Double], endIndex: Int, length: Int) -> Double? {
    guard length > 0, endIndex >= 0, endIndex < values.count, endIndex + 1 >= length else { return nil }
    let start = endIndex + 1 - length
    var total = 0.0
    for index in start...endIndex {
        total += values[index]
    }
    return total / Double(length)
}

/// One route per bar. `leveragedPrices` and `underlyingCloses` are oldest-first and the same length.
///
/// The drawdown peak resets on the day the underlying reclaims its moving average, so a
/// 2000-style crash does not block 3x buys forever after the trend has recovered. While the
/// underlying stays above the average, a fresh drop of `drawdownThreshold` still routes the
/// next buy to the 1x fund.
func fallbackRoutePoints(
    rule: FallbackRule,
    leveragedPrices: [Double],
    underlyingCloses: [Double]
) -> [FallbackRoutePoint] {
    let count = min(leveragedPrices.count, underlyingCloses.count)
    guard count > 0 else { return [] }
    var points: [FallbackRoutePoint] = []
    points.reserveCapacity(count)
    var peak = 0.0
    var trendIsUp = false
    let bars = rule.movingAverageBars
    for index in 0..<count {
        let price = leveragedPrices[index]
        let underlying = underlyingCloses[index]
        let average = trailingMovingAverage(underlyingCloses, endIndex: index, length: bars)
        let above = average.map { underlying >= $0 } ?? false
        if average == nil {
            peak = max(peak, price)
        } else if above && !trendIsUp {
            peak = price
            trendIsUp = true
        } else if above {
            peak = max(peak, price)
            trendIsUp = true
        } else {
            peak = max(peak, price)
            trendIsUp = false
        }
        let drawdown = peak > 0 ? (peak - price) / peak : 0
        let below = average.map { underlying < $0 } ?? false
        let deep = drawdown >= rule.drawdownThreshold
        let route: FallbackRoute = (rule.enabled && (deep || below)) ? .underlying : .leveraged
        points.append(FallbackRoutePoint(
            drawdown: drawdown,
            belowMovingAverage: below,
            movingAverage: average,
            route: route
        ))
    }
    return points
}

func evaluateFallback(
    rule: FallbackRule,
    leveragedPrices: [Double],
    underlyingCloses: [Double],
    costBasisDrawdown: Double? = nil
) -> FallbackDecision {
    var priceDrawdown = 0.0
    var below = false
    var average: Double? = nil
    if !leveragedPrices.isEmpty, leveragedPrices.count == underlyingCloses.count {
        if let last = fallbackRoutePoints(
            rule: rule,
            leveragedPrices: leveragedPrices,
            underlyingCloses: underlyingCloses
        ).last {
            priceDrawdown = last.drawdown
            below = last.belowMovingAverage
            average = last.movingAverage
        }
    } else if let last = underlyingCloses.last,
              let avg = trailingMovingAverage(underlyingCloses, endIndex: underlyingCloses.count - 1, length: rule.movingAverageBars) {
        average = avg
        below = last < avg
    } else if let last = leveragedPrices.last, let peak = leveragedPrices.max(), peak > 0 {
        priceDrawdown = (peak - last) / peak
    }
    let costDrawdown = max(0, costBasisDrawdown ?? 0)
    let deep = priceDrawdown >= rule.drawdownThreshold || costDrawdown >= rule.drawdownThreshold
    let route: FallbackRoute = (rule.enabled && (deep || below)) ? .underlying : .leveraged
    return FallbackDecision(
        route: route,
        priceDrawdown: max(priceDrawdown, costDrawdown),
        belowMovingAverage: below,
        movingAverage: average
    )
}

// MARK: - Synthetic 3x prices

/// Daily-reset leveraged price. Starts at 100. A loss that would finish at or below zero
/// stays at zero — a wiped fund does not come back to life the next day.
/// Expense is charged every trading day as `annualExpense / tradingDaysPerYear`.
func syntheticLeveragedPrices(
    underlying: [Double],
    leverage: Double = 3,
    annualExpense: Double = 0.009,
    tradingDaysPerYear: Double = 252
) -> [Double] {
    guard let first = underlying.first, first.isFinite else { return [] }
    var prices: [Double] = []
    prices.reserveCapacity(underlying.count)
    var price = 100.0
    let dailyExpense = tradingDaysPerYear > 0 ? annualExpense / tradingDaysPerYear : 0
    for index in underlying.indices {
        if index > 0 {
            let previous = underlying[index - 1]
            if price <= 0 || previous <= 0 {
                price = 0
            } else {
                let underlyingReturn = underlying[index] / previous - 1
                let next = price * (1 + leverage * underlyingReturn - dailyExpense)
                price = next > 0 ? next : 0
            }
        }
        prices.append(price)
    }
    return prices
}

func priceMaxDrawdown(_ prices: [Double]) -> Double {
    var peak = 0.0
    var worst = 0.0
    for price in prices {
        peak = max(peak, price)
        if peak > 0 {
            worst = max(worst, (peak - price) / peak)
        }
    }
    return worst
}

/// Same tiers as `computeLimit`: min at or above cost, mid while down, max at or below `maxAtLoss`.
func scaledBuyLimit(
    costBasis: Double,
    gain: Double,
    gainPct: Double,
    minBuy: Double,
    midBuy: Double,
    maxBuy: Double,
    maxAtLoss: Double
) -> Double {
    if costBasis == 0 { return minBuy }
    if gain < 0 && gainPct <= maxAtLoss { return maxBuy }
    if gain < 0 { return midBuy }
    return minBuy
}

// MARK: - Path comparison

struct PathRiskPoint: Identifiable, DateIdentifiable {
    let id: Int
    let date: String
    let value: Double
}

struct PathRiskAssumptions: Codable, Equatable {
    var initialCash: Double
    var weeklyDeposit: Double
    var buyEveryTradingDays: Int
    var minBuy: Double
    var midBuy: Double
    var maxBuy: Double
    /// Loss fraction that selects the max buy. -0.25 matches the app's default tier.
    var maxAtLoss: Double
    var leverage: Double
    var annualExpense: Double
    var tradingDaysPerYear: Double
    var drawdownThreshold: Double
    var movingAverageBars: Int
}

struct PathRiskBar {
    let date: String
    let underlying: Double
    let oneX: Double
    let benchmark: Double
}

struct PathRiskScenario: Codable {
    let id: String
    let title: String
    let underlyingName: String
    let oneXName: String
    let benchmarkName: String
    let notes: String
    let dates: [String]
    let underlying: [Double]
    let oneX: [Double]
    let benchmark: [Double]

    var bars: [PathRiskBar] {
        let count = [dates.count, underlying.count, oneX.count, benchmark.count].min() ?? 0
        return (0..<count).map { index in
            PathRiskBar(
                date: dates[index],
                underlying: underlying[index],
                oneX: oneX[index],
                benchmark: benchmark[index]
            )
        }
    }
}

struct PathRiskLibrary: Codable {
    let source: String
    let assumptions: PathRiskAssumptions
    let scenarios: [PathRiskScenario]
}

struct PathRiskResult {
    let finalValue: Double
    let totalContributed: Double
    let annualizedIRR: Double
    let maxDrawdown: Double
    let minimumValue: Double
    let minimumCash: Double
    let leveragedBuys: Int
    let underlyingBuys: Int
    let totalBought: Double
    let points: [PathRiskPoint]
}

struct PathComparison {
    let leveragedOnly: PathRiskResult
    let fallback: PathRiskResult
    let benchmark: PathRiskResult
    /// Peak-to-trough of the synthetic 3x price itself, not the portfolio.
    let instrumentMaxDrawdown: Double
    let instrumentEndPrice: Double
}

func loadPathRiskLibrary(from url: URL) -> PathRiskLibrary? {
    decodeJSONFile(url, as: PathRiskLibrary.self)
}

func loadBundledPathRiskLibrary() -> PathRiskLibrary? {
    guard let url = Bundle.main.url(forResource: "path-risk-daily", withExtension: "json") else { return nil }
    return loadPathRiskLibrary(from: url)
}

/// Proleptic Gregorian ordinal equal to Python's `datetime.date.toordinal()`.
func pythonDateOrdinal(year: Int, month: Int, day: Int) -> Int {
    let priorYear = year - 1
    let daysBeforeYear = priorYear * 365 + priorYear / 4 - priorYear / 100 + priorYear / 400
    let monthLengths = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var daysBeforeMonth = 0
    if month > 1 {
        for length in monthLengths[1..<month] {
            daysBeforeMonth += length
        }
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    if month > 2 && leap {
        daysBeforeMonth += 1
    }
    return daysBeforeYear + daysBeforeMonth + day
}

func pythonDateOrdinal(_ isoDate: String) -> Int {
    let parts = isoDate.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]) else { return 0 }
    return pythonDateOrdinal(year: year, month: month, day: day)
}

/// Money-weighted annual return. Contributions are positive amounts the investor paid in.
/// The terminal portfolio value, including leftover cash, is the final inflow.
func annualizedIRR(contributions: [(date: String, amount: Double)], finalValue: Double, finalDate: String) -> Double {
    guard !contributions.isEmpty else { return .nan }
    var flows: [(day: Int, amount: Double)] = contributions.map {
        (day: pythonDateOrdinal($0.date), amount: -$0.amount)
    }
    flows.append((day: pythonDateOrdinal(finalDate), amount: finalValue))
    let start = flows[0].day
    func netPresentValue(_ rate: Double) -> Double {
        var total = 0.0
        for flow in flows {
            total += flow.amount / pow(1 + rate, Double(flow.day - start) / 365.0)
        }
        return total
    }
    var low = -0.95
    var high = 2.0
    var lowValue = netPresentValue(low)
    var highValue = netPresentValue(high)
    if lowValue * highValue > 0 { return .nan }
    for _ in 0..<80 {
        let mid = (low + high) / 2
        let midValue = netPresentValue(mid)
        if abs(midValue) < 1e-8 { return mid }
        if lowValue * midValue <= 0 {
            high = mid
            highValue = midValue
        } else {
            low = mid
            lowValue = midValue
        }
    }
    return (low + high) / 2
}

func compareLeveragedPath(bars: [PathRiskBar], assumptions: PathRiskAssumptions) -> PathComparison? {
    guard bars.count >= 2 else { return nil }
    let underlying = bars.map(\.underlying)
    let oneX = bars.map(\.oneX)
    let benchmark = bars.map(\.benchmark)
    let leveraged = syntheticLeveragedPrices(
        underlying: underlying,
        leverage: assumptions.leverage,
        annualExpense: assumptions.annualExpense,
        tradingDaysPerYear: assumptions.tradingDaysPerYear
    )
    guard leveraged.count == bars.count else { return nil }
    let rule = FallbackRule(
        enabled: true,
        drawdownThreshold: assumptions.drawdownThreshold,
        movingAverageBars: assumptions.movingAverageBars
    )
    let routes = fallbackRoutePoints(rule: rule, leveragedPrices: leveraged, underlyingCloses: underlying)
    guard routes.count == bars.count else { return nil }

    let only = runPathPortfolio(
        bars: bars,
        leveragedPrices: leveraged,
        oneXPrices: oneX,
        routes: Array(repeating: false, count: bars.count),
        buySchedule: nil,
        assumptions: assumptions
    )
    var schedule: [String: Double] = [:]
    schedule.reserveCapacity(only.buys.count)
    for buy in only.buys {
        schedule[buy.date] = buy.amount
    }
    let withFallback = runPathPortfolio(
        bars: bars,
        leveragedPrices: leveraged,
        oneXPrices: oneX,
        routes: routes.map { $0.route == .underlying },
        buySchedule: schedule,
        assumptions: assumptions
    )
    let held = runBenchmarkPortfolio(bars: bars, benchmarkPrices: benchmark, buySchedule: schedule, assumptions: assumptions)
    return PathComparison(
        leveragedOnly: only.result,
        fallback: withFallback.result,
        benchmark: held,
        instrumentMaxDrawdown: priceMaxDrawdown(leveraged),
        instrumentEndPrice: leveraged.last ?? 0
    )
}

private struct PathBuy {
    let date: String
    let amount: Double
}

private struct PathPortfolioDraft {
    var result: PathRiskResult
    var buys: [PathBuy]
    var contributions: [(date: String, amount: Double)]
}

private func runPathPortfolio(
    bars: [PathRiskBar],
    leveragedPrices: [Double],
    oneXPrices: [Double],
    routes: [Bool],
    buySchedule: [String: Double]?,
    assumptions: PathRiskAssumptions
) -> PathPortfolioDraft {
    let every = max(1, assumptions.buyEveryTradingDays)
    var cash = 0.0
    var leveragedShares = 0.0
    var underlyingShares = 0.0
    var cost = 0.0
    var buys: [PathBuy] = []
    var contributions: [(date: String, amount: Double)] = []
    var points: [PathRiskPoint] = []
    points.reserveCapacity(bars.count)
    var peakValue = 0.0
    var maxDrawdown = 0.0
    var minimumValue = Double.greatestFiniteMagnitude
    var minimumCash = Double.greatestFiniteMagnitude
    var leveragedBuys = 0
    var underlyingBuys = 0
    var totalBought = 0.0

    for index in bars.indices {
        let bar = bars[index]
        let leveragedPrice = leveragedPrices[index]
        let oneXPrice = oneXPrices[index]
        if index % every == 0 {
            let contribution = index == 0 ? assumptions.initialCash : assumptions.weeklyDeposit
            cash += contribution
            contributions.append((date: bar.date, amount: contribution))
        }
        let equity = leveragedShares * leveragedPrice + underlyingShares * oneXPrice
        let gain = cost > 0 ? equity - cost : 0
        let gainPct = cost > 0 ? equity / cost - 1 : 0
        let amount: Double
        if let buySchedule {
            amount = min(buySchedule[bar.date] ?? 0, max(0, cash))
        } else if cash > 1e-9 {
            let limit = scaledBuyLimit(
                costBasis: cost,
                gain: gain,
                gainPct: gainPct,
                minBuy: assumptions.minBuy,
                midBuy: assumptions.midBuy,
                maxBuy: assumptions.maxBuy,
                maxAtLoss: assumptions.maxAtLoss
            )
            amount = min(limit, cash)
        } else {
            amount = 0
        }
        if amount > 0.01 {
            let toUnderlying = routes[index]
            if toUnderlying && oneXPrice > 0 {
                underlyingShares += amount / oneXPrice
                cash -= amount
                cost += amount
                totalBought += amount
                underlyingBuys += 1
                buys.append(PathBuy(date: bar.date, amount: amount))
            } else if !toUnderlying && leveragedPrice > 0 {
                leveragedShares += amount / leveragedPrice
                cash -= amount
                cost += amount
                totalBought += amount
                leveragedBuys += 1
                buys.append(PathBuy(date: bar.date, amount: amount))
            }
        }
        minimumCash = min(minimumCash, cash)
        let value = leveragedShares * leveragedPrice + underlyingShares * oneXPrice + cash
        minimumValue = min(minimumValue, value)
        peakValue = max(peakValue, value)
        if peakValue > 0 {
            maxDrawdown = max(maxDrawdown, (peakValue - value) / peakValue)
        }
        points.append(PathRiskPoint(id: index, date: bar.date, value: value))
    }

    let finalValue = points.last?.value ?? cash
    let contributed = contributions.reduce(0) { $0 + $1.amount }
    let finalDate = bars.last?.date ?? ""
    let result = PathRiskResult(
        finalValue: finalValue,
        totalContributed: contributed,
        annualizedIRR: annualizedIRR(contributions: contributions, finalValue: finalValue, finalDate: finalDate),
        maxDrawdown: maxDrawdown,
        minimumValue: minimumValue == .greatestFiniteMagnitude ? finalValue : minimumValue,
        minimumCash: minimumCash == .greatestFiniteMagnitude ? cash : minimumCash,
        leveragedBuys: leveragedBuys,
        underlyingBuys: underlyingBuys,
        totalBought: totalBought,
        points: points
    )
    return PathPortfolioDraft(result: result, buys: buys, contributions: contributions)
}

private func runBenchmarkPortfolio(
    bars: [PathRiskBar],
    benchmarkPrices: [Double],
    buySchedule: [String: Double],
    assumptions: PathRiskAssumptions
) -> PathRiskResult {
    let every = max(1, assumptions.buyEveryTradingDays)
    var cash = 0.0
    var shares = 0.0
    var contributions: [(date: String, amount: Double)] = []
    var points: [PathRiskPoint] = []
    points.reserveCapacity(bars.count)
    var peakValue = 0.0
    var maxDrawdown = 0.0
    var minimumValue = Double.greatestFiniteMagnitude
    var minimumCash = Double.greatestFiniteMagnitude
    var totalBought = 0.0
    var buys = 0

    for index in bars.indices {
        let bar = bars[index]
        if index % every == 0 {
            let contribution = index == 0 ? assumptions.initialCash : assumptions.weeklyDeposit
            cash += contribution
            contributions.append((date: bar.date, amount: contribution))
        }
        let amount = min(buySchedule[bar.date] ?? 0, max(0, cash))
        let price = benchmarkPrices[index]
        if amount > 0.01 && price > 0 {
            shares += amount / price
            cash -= amount
            totalBought += amount
            buys += 1
        }
        minimumCash = min(minimumCash, cash)
        let value = shares * price + cash
        minimumValue = min(minimumValue, value)
        peakValue = max(peakValue, value)
        if peakValue > 0 {
            maxDrawdown = max(maxDrawdown, (peakValue - value) / peakValue)
        }
        points.append(PathRiskPoint(id: index, date: bar.date, value: value))
    }

    let finalValue = points.last?.value ?? cash
    let finalDate = bars.last?.date ?? ""
    return PathRiskResult(
        finalValue: finalValue,
        totalContributed: contributions.reduce(0) { $0 + $1.amount },
        annualizedIRR: annualizedIRR(contributions: contributions, finalValue: finalValue, finalDate: finalDate),
        maxDrawdown: maxDrawdown,
        minimumValue: minimumValue == .greatestFiniteMagnitude ? finalValue : minimumValue,
        minimumCash: minimumCash == .greatestFiniteMagnitude ? cash : minimumCash,
        leveragedBuys: 0,
        underlyingBuys: buys,
        totalBought: totalBought,
        points: points
    )
}
