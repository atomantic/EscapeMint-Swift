import XCTest
@testable import EscapeMint

/// Tests for FundStore import/export, TSV/JSON round-trip, and backup functionality.
/// Uses a temp directory to avoid touching real user data.
final class StorageTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscapeMintTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - TSV Round-Trip

    func testTSVRoundTripAllFields() {
        let entry = FundEntry(
            date: "2025-01-15", value: 1500.50, cash: 3000, action: .BUY,
            amount: 500, shares: 10, price: 150.05, dividend: 25.50,
            expense: 5.0, cash_interest: 1.25, fund_size: 5000,
            margin_available: 1000, margin_borrowed: 200, margin_expense: 3.5,
            notes: "test note", contracts: 2.0, entry_price: 100.0,
            liquidation_price: 50.0, unrealized_pnl: 100.0, margin_locked: 500,
            fee: 1.5, margin: 750
        )

        let tsv = buildTSV([entry])
        let parsed = parseTSV(tsv)

        XCTAssertEqual(parsed.count, 1)
        let p = parsed[0]
        XCTAssertEqual(p.date, "2025-01-15")
        XCTAssertEqual(p.value, 1500.50, accuracy: 0.01)
        XCTAssertEqual(p.cash, 3000)
        XCTAssertEqual(p.action, .BUY)
        XCTAssertEqual(p.amount, 500)
        XCTAssertEqual(p.shares, 10)
        XCTAssertEqual(p.price!, 150.05, accuracy: 0.01)
        XCTAssertEqual(p.dividend!, 25.50, accuracy: 0.01)
        XCTAssertEqual(p.expense, 5.0)
        XCTAssertEqual(p.cash_interest, 1.25)
        XCTAssertEqual(p.fund_size, 5000)
        XCTAssertEqual(p.margin_available, 1000)
        XCTAssertEqual(p.margin_borrowed, 200)
        XCTAssertEqual(p.margin_expense, 3.5)
        XCTAssertEqual(p.notes, "test note")
        XCTAssertEqual(p.contracts, 2.0)
        XCTAssertEqual(p.entry_price, 100.0)
        XCTAssertEqual(p.liquidation_price, 50.0)
        XCTAssertEqual(p.unrealized_pnl, 100.0)
        XCTAssertEqual(p.margin_locked, 500)
        XCTAssertEqual(p.fee, 1.5)
        XCTAssertEqual(p.margin, 750)
    }

    func testTSVRoundTripMinimalEntry() {
        let entry = FundEntry(date: "2025-06-01", value: 42.0)
        let tsv = buildTSV([entry])
        let parsed = parseTSV(tsv)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].date, "2025-06-01")
        XCTAssertEqual(parsed[0].value, 42.0, accuracy: 0.01)
        XCTAssertNil(parsed[0].cash)
        XCTAssertNil(parsed[0].action)
        XCTAssertNil(parsed[0].amount)
        XCTAssertNil(parsed[0].shares)
    }

    func testTSVRoundTripMultipleEntries() {
        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500),
            FundEntry(date: "2025-01-08", value: 1050, action: .HOLD),
            FundEntry(date: "2025-01-15", value: 1100, action: .SELL, amount: 200),
            FundEntry(date: "2025-01-22", value: 900, action: .BUY, amount: 100),
        ]
        let tsv = buildTSV(entries)
        let parsed = parseTSV(tsv)

        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(parsed[0].action, .BUY)
        XCTAssertEqual(parsed[1].action, .HOLD)
        XCTAssertEqual(parsed[2].action, .SELL)
        XCTAssertEqual(parsed[3].action, .BUY)
    }

    func testTSVNotesEscapeRoundTrip() {
        let entry = FundEntry(date: "2025-01-01", value: 100, notes: "line1\tcolumn2\nnewline")
        let tsv = buildTSV([entry])
        let parsed = parseTSV(tsv)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].notes, "line1\tcolumn2\nnewline")
    }

    func testTSVNotesUnicodeRoundTrip() {
        // Emoji, combining marks, RTL. All must survive TSV serialization
        // since notes is the only free-form user-entered field.
        let notes = "✅ café — Ω شكرا 🎉 a\u{0301}"  // emoji + accented + RTL + combining
        let entry = FundEntry(date: "2025-01-01", value: 100, notes: notes)
        let tsv = buildTSV([entry])
        let parsed = parseTSV(tsv)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].notes, notes)
    }

    func testTSVWindowsLineEndings() {
        let tsv = "date\tvalue\tcash\taction\r\n2025-01-01\t1000\t\tBUY\r\n"
        let parsed = parseTSV(tsv)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].date, "2025-01-01")
        XCTAssertEqual(parsed[0].value, 1000)
    }

    func testTSVAllActions() {
        var entries: [FundEntry] = []
        for action in FundAction.allCases {
            entries.append(FundEntry(date: "2025-01-01", value: 100, action: action, amount: 10))
        }
        let tsv = buildTSV(entries)
        let parsed = parseTSV(tsv)

        XCTAssertEqual(parsed.count, FundAction.allCases.count)
        for (i, action) in FundAction.allCases.enumerated() {
            XCTAssertEqual(parsed[i].action, action, "Action mismatch at index \(i)")
        }
    }

    // MARK: - JSON Config Round-Trip

    func testFundConfigJSONRoundTrip() {
        let config = FundConfig(
            platform: "coinbase", ticker: "BTC",
            fund_type: .crypto, status: .active, category: .sov,
            target_apy: 0.15, interval_days: 7,
            input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
            max_at_pct: -0.30, min_profit_usd: 100,
            cash_apy: 0.05, manage_cash: true, cash_fund: "coinbase-cash",
            margin_enabled: false, accumulate: true,
            dividend_reinvest: true, interest_reinvest: true, expense_from_fund: true,
            initial_margin_rate: 0.1, maintenance_margin_rate: 0.05, contract_multiplier: 100
        )

        let data = try! JSONEncoder.pretty.encode(config)
        let decoded = try! JSONDecoder().decode(FundConfig.self, from: data)

        XCTAssertEqual(decoded.platform, "coinbase")
        XCTAssertEqual(decoded.ticker, "BTC")
        XCTAssertEqual(decoded.fund_type, .crypto)
        XCTAssertEqual(decoded.status, .active)
        XCTAssertEqual(decoded.category, .sov)
        XCTAssertEqual(decoded.target_apy, 0.15)
        XCTAssertEqual(decoded.interval_days, 7)
        XCTAssertEqual(decoded.input_min_usd, 100)
        XCTAssertEqual(decoded.input_mid_usd, 150)
        XCTAssertEqual(decoded.input_max_usd, 200)
        XCTAssertEqual(decoded.max_at_pct, -0.30)
        XCTAssertEqual(decoded.min_profit_usd, 100)
        XCTAssertEqual(decoded.cash_apy, 0.05)
        XCTAssertEqual(decoded.manage_cash, true)
        XCTAssertEqual(decoded.cash_fund, "coinbase-cash")
        XCTAssertEqual(decoded.margin_enabled, false)
        XCTAssertEqual(decoded.accumulate, true)
        XCTAssertEqual(decoded.dividend_reinvest, true)
        XCTAssertEqual(decoded.interest_reinvest, true)
        XCTAssertEqual(decoded.expense_from_fund, true)
        XCTAssertEqual(decoded.initial_margin_rate, 0.1)
        XCTAssertEqual(decoded.maintenance_margin_rate, 0.05)
        XCTAssertEqual(decoded.contract_multiplier, 100)
    }

    func testFundConfigDerivativesFields() {
        let config = FundConfig(
            fund_type: .derivatives, status: .active,
            initial_margin_rate: 0.10, maintenance_margin_rate: 0.05, contract_multiplier: 100
        )
        let data = try! JSONEncoder.pretty.encode(config)
        let decoded = try! JSONDecoder().decode(FundConfig.self, from: data)

        XCTAssertEqual(decoded.fund_type, .derivatives)
        XCTAssertEqual(decoded.initial_margin_rate, 0.10)
        XCTAssertEqual(decoded.maintenance_margin_rate, 0.05)
        XCTAssertEqual(decoded.contract_multiplier, 100)
    }

    func testFundConfigChartBoundsRoundTrip() {
        var config = FundConfig()
        config.chart_bounds = [
            "value": ChartBounds(yMin: 0, yMax: 1000),
            "gain": ChartBounds(yMin: -100, yMax: 500)
        ]

        let data = try! JSONEncoder.pretty.encode(config)
        let decoded = try! JSONDecoder().decode(FundConfig.self, from: data)

        XCTAssertEqual(decoded.chart_bounds?["value"], ChartBounds(yMin: 0, yMax: 1000))
        XCTAssertEqual(decoded.chart_bounds?["gain"], ChartBounds(yMin: -100, yMax: 500))
    }

    // MARK: - Backup JSON Format

    func testBackupJSONStructure() {
        let fund = FundData(
            platform: "coinbase", ticker: "BTC",
            config: FundConfig(
                platform: "coinbase", ticker: "BTC",
                fund_type: .crypto, status: .active,
                target_apy: 0.15, interval_days: 7,
                input_min_usd: 100, input_mid_usd: 150, input_max_usd: 200,
                max_at_pct: -0.25, min_profit_usd: 500,
                cash_apy: 0.04, accumulate: true
            ),
            entries: [
                FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500, shares: 10),
                FundEntry(date: "2025-01-08", value: 1100, action: .HOLD, dividend: 5.0),
            ]
        )

        // Build a backup-style JSON dict from the fund
        var configDict: [String: Any] = [:]
        let configData = try! JSONEncoder.pretty.encode(fund.config)
        if let parsed = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            configDict = parsed
        }

        let entriesArray: [[String: Any]] = fund.entries.map { entry in
            var d: [String: Any] = ["date": entry.date, "value": entry.value]
            if let v = entry.action { d["action"] = v.rawValue }
            if let v = entry.amount { d["amount"] = v }
            if let v = entry.shares { d["shares"] = v }
            if let v = entry.dividend { d["dividend"] = v }
            return d
        }

        let backup: [String: Any] = [
            "version": "1.0.0",
            "backup_date": "2025-01-15T00:00:00Z",
            "funds": [[
                "id": fund.id,
                "platform": fund.platform,
                "ticker": fund.ticker,
                "config": configDict,
                "entries": entriesArray
            ]]
        ]

        let data = try! JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
        let reparsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(reparsed["version"] as? String, "1.0.0")
        let funds = reparsed["funds"] as! [[String: Any]]
        XCTAssertEqual(funds.count, 1)
        XCTAssertEqual(funds[0]["platform"] as? String, "coinbase")
        XCTAssertEqual(funds[0]["ticker"] as? String, "BTC")
        let entries = funds[0]["entries"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["action"] as? String, "BUY")
        XCTAssertEqual(entries[1]["dividend"] as? Double, 5.0)
    }

    // MARK: - Directory Import/Export

    func testDirectoryImportExport() {
        // Create source directory with a fund's TSV and JSON
        let sourceDir = tempDir.appendingPathComponent("source")
        try! FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let config = FundConfig(
            platform: "testplatform", ticker: "ABC",
            fund_type: .stock, status: .active,
            target_apy: 0.10, interval_days: 7
        )
        let configData = try! JSONEncoder.pretty.encode(config)
        try! configData.write(to: sourceDir.appendingPathComponent("testplatform-ABC.json"))

        let entries = [
            FundEntry(date: "2025-01-01", value: 1000, action: .BUY, amount: 500),
            FundEntry(date: "2025-01-08", value: 1050, action: .HOLD),
        ]
        let tsv = buildTSV(entries)
        try! tsv.write(to: sourceDir.appendingPathComponent("testplatform-ABC.tsv"),
                       atomically: true, encoding: .utf8)

        // Create dest directory
        let destDir = tempDir.appendingPathComponent("dest")
        try! FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Copy manually (simulating import)
        let fm = FileManager.default
        let tsvFiles = try! fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tsv" }

        var imported = 0
        for tsvFile in tsvFiles {
            let baseName = tsvFile.deletingPathExtension().lastPathComponent
            let jsonFile = sourceDir.appendingPathComponent("\(baseName).json")
            guard fm.fileExists(atPath: jsonFile.path) else { continue }
            try! fm.copyItem(at: tsvFile, to: destDir.appendingPathComponent(tsvFile.lastPathComponent))
            try! fm.copyItem(at: jsonFile, to: destDir.appendingPathComponent(jsonFile.lastPathComponent))
            imported += 1
        }

        XCTAssertEqual(imported, 1)

        // Verify the imported files
        let importedTSV = try! String(contentsOf: destDir.appendingPathComponent("testplatform-ABC.tsv"), encoding: .utf8)
        let importedEntries = parseTSV(importedTSV)
        XCTAssertEqual(importedEntries.count, 2)
        XCTAssertEqual(importedEntries[0].action, .BUY)
        XCTAssertEqual(importedEntries[0].amount, 500)

        let importedJSON = try! Data(contentsOf: destDir.appendingPathComponent("testplatform-ABC.json"))
        let importedConfig = try! JSONDecoder().decode(FundConfig.self, from: importedJSON)
        XCTAssertEqual(importedConfig.fund_type, .stock)
        XCTAssertEqual(importedConfig.target_apy, 0.10)
    }

    // MARK: - Backup JSON Import Parsing

    func testBackupJSONImportParsing() {
        // Create a backup JSON and verify it can be parsed
        let backupJSON: [String: Any] = [
            "version": "1.0.0",
            "backup_date": "2025-01-15T00:00:00Z",
            "funds": [
                [
                    "id": "myplatform-btc",
                    "platform": "myplatform",
                    "ticker": "btc",
                    "config": [
                        "fund_type": "crypto",
                        "status": "active",
                        "target_apy": 0.15,
                        "interval_days": 7,
                        "input_min_usd": 100,
                        "accumulate": true
                    ] as [String: Any],
                    "entries": [
                        ["date": "2025-01-01", "value": 1000, "action": "BUY", "amount": 500, "shares": 10.0] as [String: Any],
                        ["date": "2025-01-08", "value": 1100, "action": "HOLD"] as [String: Any],
                        ["date": "2025-01-15", "value": 1200, "action": "SELL", "amount": 200, "shares": 4.0] as [String: Any]
                    ]
                ] as [String: Any]
            ]
        ]

        let data = try! JSONSerialization.data(withJSONObject: backupJSON)
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let funds = parsed["funds"] as! [[String: Any]]

        XCTAssertEqual(funds.count, 1)
        let fund = funds[0]
        XCTAssertEqual(fund["id"] as? String, "myplatform-btc")
        XCTAssertEqual(fund["platform"] as? String, "myplatform")

        let entries = fund["entries"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0]["action"] as? String, "BUY")
        XCTAssertEqual(entries[2]["action"] as? String, "SELL")
    }

    func testBackupJSONSkipsTestFunds() {
        // Verify test platform detection works for import filtering
        XCTAssertTrue(isTestPlatform("coinbasetest"))
        XCTAssertTrue(isTestPlatform("robinhoodtest"))
        XCTAssertTrue(isTestPlatform("demoAccount"))
        XCTAssertFalse(isTestPlatform("coinbase"))
        XCTAssertFalse(isTestPlatform("robinhood"))
    }

    func testBackupJSONInvalidFormatHandling() async throws {
        // Previously this test only exercised the Swift stdlib `JSONSerialization` — a bug
        // in `FundStore.importFromBackupJSON` would not have failed it. Now we actually call
        // the production method against temp files with malformed content and verify it
        // throws or returns 0-imported.
        let store = FundStore.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapemint-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Empty JSON — no "funds" key → should throw (invalid backup format)
        let emptyURL = tempDir.appendingPathComponent("empty.json")
        try "{}".data(using: .utf8)!.write(to: emptyURL)
        do {
            _ = try await store.importFromBackupJSON(emptyURL)
            XCTFail("Expected importFromBackupJSON to throw on missing 'funds' key")
        } catch {
            // expected
        }

        // Present but empty funds array → should return 0 imported, no throw
        let zeroFundsURL = tempDir.appendingPathComponent("zero.json")
        try #"{"version":"1.0.0","funds":[]}"#.data(using: .utf8)!.write(to: zeroFundsURL)
        let zeroCount = try await store.importFromBackupJSON(zeroFundsURL)
        XCTAssertEqual(zeroCount, 0)
    }

    // MARK: - TSV Column Building

    func testBuildTSVHasCorrectHeaders() {
        let tsv = buildTSV([])
        let lines = tsv.split(separator: "\n")
        XCTAssertEqual(lines.count, 1) // header only
        let headers = lines[0].split(separator: "\t").map(String.init)
        XCTAssertEqual(headers.count, 22)
        XCTAssertEqual(headers[0], "date")
        XCTAssertEqual(headers[1], "value")
        XCTAssertEqual(headers[2], "cash")
        XCTAssertEqual(headers[3], "action")
        XCTAssertEqual(headers[14], "notes")
        XCTAssertEqual(headers[20], "fee")
        XCTAssertEqual(headers[21], "margin")
    }

    func testSerializeEntryColumnCount() {
        let entry = FundEntry(date: "2025-01-01", value: 100)
        let serialized = serializeEntry(entry)
        let parts = serialized.split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 22)
    }

    // MARK: - FundData Identity

    func testFundDataId() {
        let fund = FundData(
            platform: "coinbase", ticker: "BTC",
            config: FundConfig(), entries: []
        )
        XCTAssertEqual(fund.id, "coinbase-BTC")
    }

    func testFundDataIdCaseSensitive() {
        let fund1 = FundData(platform: "Coinbase", ticker: "btc", config: FundConfig(), entries: [])
        let fund2 = FundData(platform: "coinbase", ticker: "BTC", config: FundConfig(), entries: [])
        XCTAssertNotEqual(fund1.id, fund2.id)
    }

    // MARK: - Backup JSON Entry Serialization

    func testBackupEntryRoundTripThroughTSV() {
        // Simulate the backup JSON -> TSV -> parseTSV pipeline
        let entryDict: [String: Any] = [
            "date": "2025-03-01",
            "value": 1500.0,
            "cash": 3000.0,
            "action": "BUY",
            "amount": 500.0,
            "shares": 10.0,
            "price": 150.0,
            "dividend": 25.0,
            "notes": "test note with\ttab"
        ]

        // Build TSV line from dict (matching importFromBackupJSON logic)
        let cols: [String] = [
            entryDict["date"] as? String ?? "",
            formatTestNum(entryDict["value"]),
            formatTestNum(entryDict["cash"]),
            entryDict["action"] as? String ?? "",
            formatTestNum(entryDict["amount"]),
            formatTestNum(entryDict["shares"]),
            formatTestNum(entryDict["price"]),
            formatTestNum(entryDict["dividend"]),
            "", "", "", "", "", "",
            (entryDict["notes"] as? String ?? "")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\n", with: "\\n"),
            "", "", "", "", "", "", ""
        ]
        let line = cols.joined(separator: "\t")

        let headers = ["date", "value", "cash", "action", "amount", "shares", "price",
                       "dividend", "expense", "cash_interest", "fund_size",
                       "margin_available", "margin_borrowed", "margin_expense",
                       "notes", "contracts", "entry_price", "liquidation_price",
                       "unrealized_pnl", "margin_locked", "fee", "margin"]

        let entry = parseEntry(line, headers: headers)
        XCTAssertEqual(entry.date, "2025-03-01")
        XCTAssertEqual(entry.value, 1500.0, accuracy: 0.01)
        XCTAssertEqual(entry.cash, 3000.0)
        XCTAssertEqual(entry.action, .BUY)
        XCTAssertEqual(entry.amount, 500.0)
        XCTAssertEqual(entry.shares, 10.0)
        XCTAssertEqual(entry.price, 150.0)
        XCTAssertEqual(entry.dividend, 25.0)
        XCTAssertEqual(entry.notes, "test note with\ttab")
    }

    // MARK: - Safe Fund ID Validation

    func testSafeFundIdPattern() {
        let pattern = /^[a-zA-Z0-9._-]+$/
        XCTAssertNotNil("coinbase-btc".wholeMatch(of: pattern))
        XCTAssertNotNil("robinhood_AAPL".wholeMatch(of: pattern))
        XCTAssertNotNil("platform.ticker".wholeMatch(of: pattern))
        XCTAssertNil("../etc/passwd".wholeMatch(of: pattern))
        XCTAssertNil("fund id with spaces".wholeMatch(of: pattern))
        XCTAssertNil("fund/path".wholeMatch(of: pattern))
    }

    // MARK: - FundDataStore.applyRenames

    func testApplyRenamesSwapsFundByOldId() {
        let btc = FundData(platform: "coinbase", ticker: "btc",
                           config: FundConfig(fund_type: .crypto), entries: [])
        let eth = FundData(platform: "coinbase", ticker: "eth",
                           config: FundConfig(fund_type: .crypto), entries: [])
        let renamedBTC = FundData(platform: "cb", ticker: "btc",
                                  config: btc.config, entries: btc.entries)

        let result = FundDataStore.applyRenames(
            to: [btc, eth],
            edits: [("coinbase-btc", renamedBTC)]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains(where: { $0.id == "cb-btc" }))
        XCTAssertFalse(result.contains(where: { $0.id == "coinbase-btc" }))
        XCTAssertTrue(result.contains(where: { $0.id == "coinbase-eth" }),
                      "Untouched funds should be preserved")
    }

    func testApplyRenamesBatchHandlesPlatformWideRename() {
        let btc = FundData(platform: "coinbase", ticker: "btc",
                           config: FundConfig(fund_type: .crypto), entries: [])
        let eth = FundData(platform: "coinbase", ticker: "eth",
                           config: FundConfig(fund_type: .crypto), entries: [])
        let tqqq = FundData(platform: "robinhood", ticker: "tqqq",
                            config: FundConfig(fund_type: .stock), entries: [])

        let edits: [(oldId: String, newFund: FundData)] = [
            ("coinbase-btc", FundData(platform: "cb", ticker: "btc", config: btc.config, entries: [])),
            ("coinbase-eth", FundData(platform: "cb", ticker: "eth", config: eth.config, entries: [])),
        ]
        let result = FundDataStore.applyRenames(to: [btc, eth, tqqq], edits: edits)

        let platforms = Set(result.map(\.platform))
        XCTAssertEqual(platforms, ["cb", "robinhood"])
        XCTAssertEqual(result.count, 3)
    }

    func testApplyRenamesIgnoresUnknownOldId() {
        let btc = FundData(platform: "coinbase", ticker: "btc",
                           config: FundConfig(fund_type: .crypto), entries: [])
        let result = FundDataStore.applyRenames(
            to: [btc],
            edits: [("nonexistent-fund", btc)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "coinbase-btc")
    }

    // MARK: - DataStats

    func testDataStatsFormattedSize() {
        let small = FundStore.DataStats(fundCount: 1, totalBytes: 500)
        XCTAssertEqual(small.formattedSize, "500 B")

        let medium = FundStore.DataStats(fundCount: 5, totalBytes: 15360)
        XCTAssertEqual(medium.formattedSize, "15.0 KB")

        let large = FundStore.DataStats(fundCount: 20, totalBytes: 2_621_440)
        XCTAssertEqual(large.formattedSize, "2.5 MB")
    }
}

// MARK: - Test Helpers

private func formatTestNum(_ value: Any?) -> String {
    guard let v = value else { return "" }
    switch v {
    case let n as NSNumber:
        let d = n.doubleValue
        return d == 0 ? "" : String(d)
    case let s as String:
        return s
    default:
        return ""
    }
}
