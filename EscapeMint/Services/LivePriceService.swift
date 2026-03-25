import Foundation
import os

/// Fetches live prices from CoinGecko (crypto) and Yahoo Finance (stocks).
/// Caches results with a 5-minute TTL to stay within free-tier rate limits.
@MainActor @Observable
final class LivePriceService {
    static let shared = LivePriceService()

    private(set) var prices: [String: PriceData] = [:]
    private(set) var lastFetched: Date?
    private(set) var isFetching = false

    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "LivePrice")
    static let cacheTTLSeconds: TimeInterval = 300

    struct PriceData: Sendable {
        let price: Double
        let change24h: Double
        let fetchedAt: Date

        var isStale: Bool {
            Date().timeIntervalSince(fetchedAt) > 300
        }
    }

    private init() {}

    private static let cryptoMap: [String: String] = [
        "btc": "bitcoin", "eth": "ethereum", "sol": "solana",
        "ada": "cardano", "dot": "polkadot", "avax": "avalanche-2",
        "matic": "matic-network", "link": "chainlink", "uni": "uniswap",
        "doge": "dogecoin", "xrp": "ripple", "ltc": "litecoin",
        "atom": "cosmos", "near": "near", "apt": "aptos",
        "sui": "sui", "arb": "arbitrum", "op": "optimism",
    ]

    func fetchPrices(for funds: [FundData]) async {
        guard !isFetching else { return }
        if let last = lastFetched, Date().timeIntervalSince(last) < Self.cacheTTLSeconds { return }

        isFetching = true
        defer { isFetching = false }

        var cryptoIds: [(fundKey: String, coinId: String)] = []
        var stockTickers: [String] = []

        for fund in funds {
            guard fund.config.status != .closed else { continue }
            guard let fundType = fund.config.fund_type else { continue }
            if isCashFund(fundType) || fundType == .derivatives { continue }

            let ticker = fund.ticker.lowercased()
            if fundType == .crypto {
                if let coinId = Self.cryptoMap[ticker] {
                    cryptoIds.append((fundKey: ticker, coinId: coinId))
                }
            } else {
                stockTickers.append(fund.ticker.uppercased())
            }
        }

        if !cryptoIds.isEmpty {
            await fetchCryptoPrices(cryptoIds)
        }
        if !stockTickers.isEmpty {
            await fetchStockPrices(stockTickers)
        }

        lastFetched = Date()
    }

    func price(for ticker: String) -> PriceData? {
        prices[ticker.lowercased()]
    }

    func unrealizedPnL(for fund: FundData) -> Double? {
        guard let pd = price(for: fund.ticker) else { return nil }
        guard let lastEntry = fund.entries.last else { return nil }
        guard let shares = lastEntry.shares, shares > 0 else { return nil }
        guard let entryPrice = lastEntry.price, entryPrice > 0 else { return nil }
        return (pd.price - entryPrice) * shares
    }

    // MARK: - CoinGecko

    private func fetchCryptoPrices(_ ids: [(fundKey: String, coinId: String)]) async {
        let coinIds = ids.map(\.coinId).joined(separator: ",")
        let urlStr = "https://api.coingecko.com/api/v3/simple/price?ids=\(coinIds)&vs_currencies=usd&include_24hr_change=true"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }

            let now = Date()
            for (fundKey, coinId) in ids {
                guard let coinData = json[coinId],
                      let price = coinData["usd"] as? Double else { continue }
                let change = coinData["usd_24h_change"] as? Double ?? 0
                prices[fundKey] = PriceData(price: price, change24h: change, fetchedAt: now)
            }
        } catch {
            Self.logger.error("CoinGecko fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Yahoo Finance

    private func fetchStockPrices(_ tickers: [String]) async {
        for ticker in tickers {
            let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)?interval=1d&range=2d"
            guard let url = URL(string: urlStr) else { continue }

            do {
                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let chart = json["chart"] as? [String: Any],
                      let results = chart["result"] as? [[String: Any]],
                      let result = results.first,
                      let meta = result["meta"] as? [String: Any],
                      let price = meta["regularMarketPrice"] as? Double,
                      let prevClose = meta["previousClose"] as? Double else { continue }

                let change = prevClose > 0 ? ((price - prevClose) / prevClose) * 100 : 0
                prices[ticker.lowercased()] = PriceData(price: price, change24h: change, fetchedAt: Date())
            } catch {
                Self.logger.error("Yahoo Finance fetch failed for \(ticker): \(error.localizedDescription)")
            }
        }
    }
}
