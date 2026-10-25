import Foundation

// MARK: - Historical Data Loading

/// Loads the bundled weekly historical price series used by the backtest engine.
///
/// This performs bundle I/O (reading JSON resources), so it lives in Services rather
/// than Engine — the Engine layer stays pure and receives the loaded data as a parameter.
/// QQQ, SOXX, and SOXL use the same Wednesday grid as the older files. Each JSON file
/// records that the prices are Yahoo Finance split-adjusted closes.
func loadHistoricalData() -> [String: HistoricalData] {
    let tickers = ["btc", "tqqq", "spxl", "vti", "brgnx", "gld", "slv", "qqq", "soxx", "soxl"]
    var result: [String: HistoricalData] = [:]
    for ticker in tickers {
        guard let url = Bundle.main.url(forResource: "\(ticker)-weekly", withExtension: "json"),
              let hist = decodeJSONFile(url, as: HistoricalData.self) else {
            continue
        }
        result[ticker.uppercased()] = hist
    }
    return result
}

/// Price history for an opted-in fund. Ordinary funds never reach this.
/// Weekly bundled closes are the sample series; 200 days is read as 40 weeks.
func fallbackContext(for fund: FundData, state: FundState) -> FallbackContext? {
    guard fund.config.fallbackEnabled else { return nil }
    let typed = fund.config.fallback_ticker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let ticker = typed.isEmpty ? LeveragedPairs.suggestedUnderlying(for: fund.ticker) : typed
    guard let ticker, !ticker.isEmpty else { return nil }
    let history = loadHistoricalData()
    let underlying = history[ticker.uppercased()]?.prices.map(\.value) ?? []
    let bundledLeveraged = history[fund.ticker.uppercased()]?.prices.map(\.value) ?? []
    let entryPrices = fund.entries.compactMap(\.price).filter { $0 > 0 }
    let leveraged = bundledLeveraged.count >= 2 ? bundledLeveraged : (entryPrices.count >= 2 ? entryPrices : [])
    let costDrawdown = state.startInputUsd > 0 && state.gainPct < 0 ? -state.gainPct : 0
    return FallbackContext(
        routeTicker: ticker.uppercased(),
        leveragedPrices: leveraged,
        underlyingCloses: underlying,
        movingAverageBars: fallbackMovingAverageBars(days: fund.config.fallbackMADays, cadence: .weekly),
        costBasisDrawdown: costDrawdown
    )
}
