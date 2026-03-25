import Foundation
import CoreSpotlight
import os

/// Indexes funds in Spotlight so users can search "BTC" or "Coinbase" from the home screen.
final class SpotlightIndexer: Sendable {
    static let shared = SpotlightIndexer()
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "Spotlight")
    private static let domainId = "net.shadowpuppet.EscapeMint.funds"

    private init() {}

    /// Index all funds in Spotlight. Called after each recompute.
    func indexFunds(_ funds: [FundData]) {
        var items: [CSSearchableItem] = []

        for fund in funds {
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = "\(fund.ticker.uppercased()) — \(fund.platform.capitalized)"
            attrs.contentDescription = buildDescription(fund)
            attrs.keywords = [
                fund.ticker,
                fund.ticker.uppercased(),
                fund.platform,
                fund.platform.capitalized,
                fund.config.fund_type?.rawValue ?? "",
                fund.config.category?.rawValue ?? "",
                "EscapeMint"
            ]

            let item = CSSearchableItem(
                uniqueIdentifier: fund.id,
                domainIdentifier: Self.domainId,
                attributeSet: attrs
            )
            // Keep items in index for 30 days
            item.expirationDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())
            items.append(item)
        }

        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error {
                Self.logger.error("Spotlight indexing failed: \(error.localizedDescription)")
            }
        }
    }

    /// Remove all indexed items
    func deindexAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domainId]) { error in
            if let error {
                Self.logger.error("Spotlight deindex failed: \(error.localizedDescription)")
            }
        }
    }

    /// Remove a single fund from the index
    func deindexFund(id: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id]) { _ in }
    }

    private func buildDescription(_ fund: FundData) -> String {
        let status = fund.config.status == .closed ? "Closed" : "Active"
        let type = fund.config.fund_type?.rawValue.capitalized ?? "Fund"
        let entryCount = fund.entries.count
        let latestValue = fund.entries.last.map { formatCurrency($0.value) } ?? "$0"

        return "\(status) \(type) on \(fund.platform.capitalized) — \(entryCount) entries, latest value \(latestValue)"
    }
}
