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

    /// Mix concurrent appends and full replaces against one fund. Every observed
    /// state must be a complete submitted replacement snapshot followed by complete
    /// appends; an empty result, a dropped partial row, or a blended replacement fails.
    func testInterleavedAppendsAndReplacesAlwaysParseCleanly() async throws {
        let fundId = try await makeFund(tag: "mixed")
        let baseline = FundEntry(date: "2024-12-31", value: 1, notes: "baseline-0")
        try await store.replaceEntries(fundId: fundId, entries: [baseline])

        let replaceCount = 40
        let appendCount = 80
        let replacementSnapshots: [Int: [String]] = Dictionary(uniqueKeysWithValues: (0..<replaceCount).map { writer in
            (writer, (0..<(writer % 7 + 1)).map { "replace-\(writer)-\($0)" })
        })

        // Writers return nil. Readers return their entire observed parse, including an
        // empty array (which is deliberately retained and rejected below).
        let observations = try await withThrowingTaskGroup(of: [FundEntry]?.self, returning: [[FundEntry]].self) { group in
            for writer in 0..<replaceCount {
                group.addTask { [store] in
                    let snapshot = (0..<(writer % 7 + 1)).map { row -> FundEntry in
                        var entry = Self.makeEntry(writer * 10 + row)
                        entry.notes = "replace-\(writer)-\(row)"
                        return entry
                    }
                    try await store.replaceEntries(fundId: fundId, entries: snapshot)
                    return nil
                }
            }
            for append in 0..<appendCount {
                group.addTask { [store] in
                    var entry = Self.makeEntry(1000 + append)
                    entry.notes = "append-\(append)"
                    try await store.appendEntry(fundId: fundId, entry: entry)
                    return nil
                }
            }
            for _ in 0..<(replaceCount + appendCount) {
                group.addTask { [store] in
                    // Yield so these reads interleave with writes rather than all
                    // necessarily observing the seeded baseline before the storm.
                    await Task.yield()
                    return store.readFundEntries(id: fundId)
                }
            }

            var reads: [[FundEntry]] = []
            for try await result in group {
                if let result { reads.append(result) }
            }
            return reads
        }

        XCTAssertEqual(observations.count, replaceCount + appendCount,
                       "every concurrent reader must report an observed state")
        let maybeFinal = await store.readFundById(fundId)
        let final = try XCTUnwrap(maybeFinal)
        for observed in observations + [final.entries] {
            XCTAssertFalse(observed.isEmpty, "a valid seeded fund must never parse as an empty file")
            let tags = observed.compactMap(\.notes)
            XCTAssertEqual(tags.count, observed.count, "a partial row must not lose its identifying tag")
            XCTAssertEqual(Set(tags).count, tags.count, "no entry may be duplicated or blended")

            let snapshotTags: [String]
            if tags.first == "baseline-0" {
                snapshotTags = ["baseline-0"]
            } else if let first = tags.first,
                      let writer = Int(first.split(separator: "-")[1]),
                      let expected = replacementSnapshots[writer] {
                snapshotTags = expected
            } else {
                XCTFail("state did not begin with a submitted snapshot: \(tags)")
                continue
            }
            XCTAssertGreaterThanOrEqual(tags.count, snapshotTags.count)
            XCTAssertEqual(Array(tags.prefix(snapshotTags.count)), snapshotTags,
                           "replacement portion must be complete and from one writer")
            for tag in tags.dropFirst(snapshotTags.count) {
                XCTAssertTrue(tag.hasPrefix("append-"), "only complete appends may follow a replacement: \(tag)")
            }
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
