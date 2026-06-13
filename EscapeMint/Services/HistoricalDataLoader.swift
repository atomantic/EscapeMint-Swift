import Foundation

// MARK: - Historical Data Loading

/// Loads the bundled weekly historical price series used by the backtest engine.
///
/// This performs bundle I/O (reading JSON resources), so it lives in Services rather
/// than Engine — the Engine layer stays pure and receives the loaded data as a parameter.
func loadHistoricalData() -> [String: HistoricalData] {
    let tickers = ["btc", "tqqq", "spxl", "vti", "brgnx", "gld", "slv"]
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
