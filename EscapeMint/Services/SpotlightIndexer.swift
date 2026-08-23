import Foundation
import CoreSpotlight
import os

/// Abstraction over the Spotlight index operations `SpotlightIndexer` performs.
/// Production wires in `CSSearchableIndex.default()`; tests inject a spy so the
/// items handed to Spotlight can be asserted (the real index can't be read back
/// from a unit test). Only the three methods the indexer calls are exposed.
protocol SearchableIndexing: Sendable {
    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withDomainIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)?)
}

// `CSSearchableIndex` already declares these signatures, so conformance is free.
extension CSSearchableIndex: SearchableIndexing {}

/// Indexes funds in Spotlight so users can search "BTC" or "Coinbase" from the home screen.
final class SpotlightIndexer: Sendable {
    static let shared = SpotlightIndexer()
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "Spotlight")
    private static let domainId = "net.shadowpuppet.EscapeMint.funds"

    private let index: SearchableIndexing

    /// Default initializer targets the real system index. Tests pass a spy
    /// conforming to `SearchableIndexing` to assert the items being indexed.
    init(index: SearchableIndexing = CSSearchableIndex.default()) {
        self.index = index
    }

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
            item.expirationDate = Calendar.current.date(byAdding: .day, value: 30, to: Date())
            items.append(item)
        }

        index.indexSearchableItems(items) { error in
            if let error {
                Self.logger.error("Spotlight indexing failed: \(error.localizedDescription)")
            }
        }
    }

    func deindexAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainId]) { error in
            if let error {
                Self.logger.error("Spotlight deindex failed: \(error.localizedDescription)")
            }
        }
    }

    func deindexFund(id: String) {
        index.deleteSearchableItems(withIdentifiers: [id]) { error in
            if let error {
                Self.logger.error("Spotlight deindex failed: \(error.localizedDescription)")
            }
        }
    }

    private func buildDescription(_ fund: FundData) -> String {
        // Intentionally omit monetary values. Spotlight results are visible system-wide
        // (lock screen Spotlight overlay, Siri suggestions, Notification Center) without
        // authenticating to EscapeMint, so leaking portfolio values would expose PII.
        let status = fund.config.status == .closed ? "Closed" : "Active"
        let type = fund.config.fund_type?.rawValue.capitalized ?? "Fund"
        return "\(status) \(type) on \(fund.platform.capitalized)"
    }
}
