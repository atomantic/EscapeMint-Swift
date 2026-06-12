import XCTest
@testable import EscapeMint

/// Concurrency stress tests for the actor-based `FundStore` (#65).
///
/// `FundStore` is an `actor`, so the Swift runtime serializes all calls to its
/// isolated methods. These tests fire many *overlapping* writes (appends, full
/// replaces, and mixed read/write traffic) at the store from concurrent tasks
/// and assert that:
///   - no write is lost or duplicated,
///   - the on-disk TSV always parses cleanly (no torn/interleaved bytes), and
///   - concurrent writes to different funds stay isolated from one another.
///
/// Isolation: every test creates its own uniquely-named funds via `FundStore.shared`
/// and removes them in a teardown block, so runs never collide with each other or
/// with real user data. `writeFund`/`appendEntry`/`replaceEntries`/`readFundById`
/// all key off the fund id, and the unique-per-test ids guarantee disjoint files.
final class FundStoreConcurrencyTests: XCTestCase {

    private let store = FundStore.shared

    /// Create a uniquely-named fund (so concurrent test runs never collide) seeded
    /// with a header-only TSV, and register teardown cleanup immediately.
    private func makeFund(tag: String) async throws -> String {
        let id = "concurrency-\(tag)-\(UUID().uuidString.prefix(8).lowercased())"
        let fund = FundData(
            platform: id, ticker: "x",
            config: FundConfig(fund_type: .stock, status: .active),
            entries: []
        )
        try await store.writeFund(fund)
        let fundId = fund.id
        addTeardownBlock { [store] in
            try? await store.deleteFund(id: fundId)
        }
        return fundId
    }

    // `static` so the concurrent task closures don't capture `self` (a non-Sendable
    // XCTestCase) — Swift 6 strict concurrency rejects that capture.
    private static func makeEntry(_ i: Int) -> FundEntry {
        // Distinct date per index so every appended row is uniquely identifiable
        // and order-independent verification can match on date.
        let day = String(format: "%02d", (i % 28) + 1)
        let month = String(format: "%02d", (i / 28) % 12 + 1)
        return FundEntry(
            date: "2025-\(month)-\(day)",
            value: Double(1000 + i),
            action: .BUY,
            amount: Double(i),
            shares: Double(i) * 0.5,
            notes: "row-\(i)"
        )
    }

    // MARK: - Concurrent appends to one fund

    /// Fire N concurrent `appendEntry` calls at a single fund. The actor must
    /// serialize the in-place FileHandle appends so that every line lands intact
    /// and the resulting TSV parses to exactly N rows with no corruption.
    func testConcurrentAppendsSerializeWithoutCorruption() async throws {
        let fundId = try await makeFund(tag: "append")
        let count = 200

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask { [store] in
                    try? await store.appendEntry(fundId: fundId, entry: Self.makeEntry(i))
                }
            }
        }

        let maybeReloaded = await store.readFundById(fundId)
        let reloaded = try XCTUnwrap(maybeReloaded)
        // No row lost, none duplicated — all appends serialized cleanly.
        XCTAssertEqual(reloaded.entries.count, count,
                       "Every concurrent append must land exactly once")

        // Each row must be intact: a torn append would corrupt a line such that
        // parseTSV either drops it (count would differ) or mangles its fields.
        let notes = Set(reloaded.entries.compactMap { $0.notes })
        let expected = Set((0..<count).map { "row-\($0)" })
        XCTAssertEqual(notes, expected, "All appended rows present and uncorrupted")

        // Re-reading the raw bytes must reparse to the same count — proves the
        // serialized form on disk is well-formed (no interleaved partial writes).
        // `readFundEntries` is nonisolated (true parallel I/O), so no await needed.
        XCTAssertEqual(store.readFundEntries(id: fundId).count, count)
    }

    // MARK: - Concurrent full replaces

    /// Fire many concurrent `replaceEntries` (each an atomic full rewrite) at one
    /// fund. The final on-disk state must be exactly one of the submitted snapshots
    /// — never a torn blend of two — and must always parse cleanly mid-flight.
    func testConcurrentReplacesYieldOneIntactSnapshot() async throws {
        let fundId = try await makeFund(tag: "replace")
        let writers = 50

        // Each writer replaces the whole TSV with a snapshot of a distinct size,
        // tagged in notes so we can identify which writer "won".
        await withTaskGroup(of: Void.self) { group in
            for w in 1...writers {
                group.addTask { [store] in
                    let snapshot = (0..<w).map { i -> FundEntry in
                        var e = Self.makeEntry(i)
                        e.notes = "writer-\(w)"
                        return e
                    }
                    try? await store.replaceEntries(fundId: fundId, entries: snapshot)
                }
            }
        }

        let maybeReloaded = await store.readFundById(fundId)
        let entries = try XCTUnwrap(maybeReloaded).entries
        // The surviving file must be a complete, uncorrupted snapshot from a single
        // writer: all rows share one writer tag and the count matches that tag.
        let tags = Set(entries.compactMap { $0.notes })
        XCTAssertEqual(tags.count, 1, "Final file must be one intact snapshot, not a blend")
        if let tag = tags.first, let w = Int(tag.replacingOccurrences(of: "writer-", with: "")) {
            XCTAssertEqual(entries.count, w, "Snapshot row count must match its writer")
        } else {
            XCTFail("Unexpected notes tag in final snapshot: \(tags)")
        }
    }

    // MARK: - Interleaved appends + replaces

    /// Mix concurrent appends and full replaces against one fund. Regardless of
    /// interleaving, every reload during and after the storm must parse cleanly
    /// (no exceptions, no garbage rows with empty dates being surfaced).
    func testInterleavedAppendsAndReplacesAlwaysParseCleanly() async throws {
        let fundId = try await makeFund(tag: "mixed")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<120 {
                group.addTask { [store] in
                    if i % 3 == 0 {
                        let snapshot = (0..<(i % 10 + 1)).map { Self.makeEntry($0) }
                        try? await store.replaceEntries(fundId: fundId, entries: snapshot)
                    } else {
                        try? await store.appendEntry(fundId: fundId, entry: Self.makeEntry(i))
                    }
                }
                // Concurrent readers racing the writers must never see a torn file.
                group.addTask { [store] in
                    let parsed = store.readFundEntries(id: fundId)
                    // Every surfaced row must have a non-empty date — parseTSV drops
                    // malformed rows, so a torn write can never masquerade as a zeroed entry.
                    for e in parsed {
                        XCTAssertFalse(e.date.isEmpty, "No malformed (empty-date) row may surface")
                    }
                }
            }
        }

        // Final state must still be a clean parse.
        let maybeFinal = await store.readFundById(fundId)
        let final = try XCTUnwrap(maybeFinal)
        for e in final.entries {
            XCTAssertFalse(e.date.isEmpty)
        }
    }

    // MARK: - Cross-fund isolation under concurrency

    /// Hammer several distinct funds concurrently. Each fund's writes must remain
    /// isolated: writer K's rows must only ever appear in fund K's file.
    func testConcurrentWritesToDistinctFundsStayIsolated() async throws {
        let fundCount = 8
        let appendsPerFund = 40
        var fundIds: [String] = []
        for k in 0..<fundCount {
            fundIds.append(try await makeFund(tag: "iso\(k)"))
        }

        await withTaskGroup(of: Void.self) { group in
            for (k, fundId) in fundIds.enumerated() {
                for i in 0..<appendsPerFund {
                    group.addTask { [store] in
                        var e = Self.makeEntry(i)
                        e.notes = "fund-\(k)"
                        try? await store.appendEntry(fundId: fundId, entry: e)
                    }
                }
            }
        }

        for (k, fundId) in fundIds.enumerated() {
            let maybeReloaded = await store.readFundById(fundId)
            let entries = try XCTUnwrap(maybeReloaded).entries
            XCTAssertEqual(entries.count, appendsPerFund,
                           "Fund \(k) must hold exactly its own appends")
            let foreign = entries.filter { $0.notes != "fund-\(k)" }
            XCTAssertTrue(foreign.isEmpty,
                          "Fund \(k) leaked rows from another fund: \(foreign.map { $0.notes ?? "" })")
        }
    }

    // MARK: - Concurrent config + entry writes

    /// `writeFund`, `updateConfig`, and `appendEntry` touch the same fund's JSON/TSV
    /// pair from different methods. Running them concurrently must leave both files
    /// individually valid (decodable JSON config, parseable TSV).
    func testConcurrentConfigAndEntryWritesStayValid() async throws {
        let fundId = try await makeFund(tag: "configentry")

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<80 {
                group.addTask { [store] in
                    if i % 2 == 0 {
                        var cfg = FundConfig(fund_type: .stock, status: .active)
                        cfg.target_apy = Double(i) / 100.0
                        _ = try? await store.updateConfig(fundId: fundId, config: cfg)
                    } else {
                        try? await store.appendEntry(fundId: fundId, entry: Self.makeEntry(i))
                    }
                }
            }
        }

        // Both halves must reload into a coherent FundData (config decodes, TSV parses).
        let maybeReloaded = await store.readFundById(fundId)
        let reloaded = try XCTUnwrap(maybeReloaded)
        XCTAssertEqual(reloaded.config.fund_type, .stock)
        // identity fields preserved by updateConfig's merge
        XCTAssertEqual(reloaded.id, fundId)
        for e in reloaded.entries {
            XCTAssertFalse(e.date.isEmpty)
        }
    }
}
