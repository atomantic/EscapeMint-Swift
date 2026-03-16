import Foundation

actor FundStore {
    static let shared = FundStore()

    private let fileManager = FileManager.default

    let fundsDirectory: URL
    nonisolated let isICloud: Bool

    private init() {
        let fm = FileManager.default

        // Try iCloud first, verify it's actually accessible, fall back to local
        let resolvedDir: URL
        let resolvedICloud: Bool

        if let iCloudURL = fm.url(forUbiquityContainerIdentifier: "iCloud.net.shadowpuppet.EscapeMint") {
            let funds = iCloudURL.appendingPathComponent("Documents/funds")
            var iCloudWorks = false
            do {
                try fm.createDirectory(at: funds, withIntermediateDirectories: true)
                _ = try fm.contentsOfDirectory(at: funds, includingPropertiesForKeys: nil)
                iCloudWorks = true
            } catch {
                // iCloud container exists but isn't accessible (e.g. permission denied)
            }
            if iCloudWorks {
                resolvedDir = funds
                resolvedICloud = true
            } else {
                let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let local = docs.appendingPathComponent("funds")
                try? fm.createDirectory(at: local, withIntermediateDirectories: true)
                resolvedDir = local
                resolvedICloud = false
            }
        } else {
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let funds = docs.appendingPathComponent("funds")
            try? fm.createDirectory(at: funds, withIntermediateDirectories: true)
            resolvedDir = funds
            resolvedICloud = false
        }

        self.fundsDirectory = resolvedDir
        self.isICloud = resolvedICloud
    }

    /// Migrate local funds to iCloud if iCloud became available
    func migrateToICloudIfNeeded() {
        guard isICloud else { return }
        let fm = fileManager
        let localDocs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFunds = localDocs.appendingPathComponent("funds")
        guard fm.fileExists(atPath: localFunds.path) else { return }

        guard let files = try? fm.contentsOfDirectory(at: localFunds, includingPropertiesForKeys: nil) else { return }
        let tsvFiles = files.filter { $0.pathExtension == "tsv" }
        guard !tsvFiles.isEmpty else { return }

        for tsvFile in tsvFiles {
            let name = tsvFile.lastPathComponent
            let destTSV = fundsDirectory.appendingPathComponent(name)
            if !fm.fileExists(atPath: destTSV.path) {
                try? fm.copyItem(at: tsvFile, to: destTSV)
            }
            let jsonFile = tsvFile.deletingPathExtension().appendingPathExtension("json")
            let destJSON = fundsDirectory.appendingPathComponent(jsonFile.lastPathComponent)
            if fm.fileExists(atPath: jsonFile.path) && !fm.fileExists(atPath: destJSON.path) {
                try? fm.copyItem(at: jsonFile, to: destJSON)
            }
        }
    }

    // MARK: - Read

    func readAllFunds() -> [FundData] {
        let dir = fundsDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "tsv" }
            .compactMap { readFund(tsvURL: $0) }
    }

    /// Read only JSON configs (no TSV entries) — returns FundData with empty entries for instant sidebar/nav
    nonisolated func readAllFundConfigs() -> [FundData] {
        let dir = fundsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { readFundConfig(jsonURL: $0) }
    }

    /// Read entries for a single fund by its id — nonisolated for true parallel I/O
    nonisolated func readFundEntries(id: String) -> [FundEntry] {
        let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
        guard let content = try? String(contentsOf: tsvURL, encoding: .utf8) else { return [] }
        return parseTSV(content)
    }

    /// Shared JSON config reader — used by both readAllFundConfigs and readFund
    private nonisolated func readFundConfig(jsonURL: URL) -> FundData? {
        guard let configData = try? Data(contentsOf: jsonURL),
              var config = try? JSONDecoder().decode(FundConfig.self, from: configData),
              let platform = config.platform, let ticker = config.ticker else { return nil }
        config.platform = nil
        config.ticker = nil
        return FundData(platform: platform, ticker: ticker, config: config, entries: [])
    }

    func readFund(tsvURL: URL) -> FundData? {
        let configURL = tsvURL.deletingPathExtension().appendingPathExtension("json")
        guard fileManager.fileExists(atPath: tsvURL.path),
              var fund = readFundConfig(jsonURL: configURL) else { return nil }

        guard let tsvContent = try? String(contentsOf: tsvURL, encoding: .utf8) else { return nil }
        fund.entries = parseTSV(tsvContent)
        return fund
    }

    func readFundById(_ id: String) -> FundData? {
        let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
        return readFund(tsvURL: tsvURL)
    }

    // MARK: - Write

    func writeFund(_ fund: FundData) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fund.id).tsv")
        let configURL = fundsDirectory.appendingPathComponent("\(fund.id).json")

        // Write config with metadata
        var configWithMeta = fund.config
        configWithMeta.platform = fund.platform
        configWithMeta.ticker = fund.ticker
        let configData = try JSONEncoder.pretty.encode(configWithMeta)
        try configData.write(to: configURL)

        // Write entries
        let tsv = buildTSV(fund.entries)
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
    }

    func appendEntry(fundId: String, entry: FundEntry) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fundId).tsv")
        guard fileManager.fileExists(atPath: tsvURL.path) else { return }
        let line = serializeEntry(entry) + "\n"
        guard let lineData = line.data(using: .utf8) else {
            throw NSError(domain: "FundStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode entry as UTF-8"])
        }
        let handle = try FileHandle(forWritingTo: tsvURL)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(lineData)
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fundId).tsv")
        guard fileManager.fileExists(atPath: tsvURL.path) else { return }
        let tsv = buildTSV(entries)
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
    }

    func updateConfig(fundId: String, config: FundConfig) throws {
        let configURL = fundsDirectory.appendingPathComponent("\(fundId).json")
        guard fileManager.fileExists(atPath: configURL.path) else { return }

        guard let existing = try? Data(contentsOf: configURL),
              let existingConfig = try? JSONDecoder().decode(FundConfig.self, from: existing) else { return }

        var updated = config
        updated.platform = existingConfig.platform
        updated.ticker = existingConfig.ticker
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(to: configURL)
    }

    func deleteFund(id: String) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
        let configURL = fundsDirectory.appendingPathComponent("\(id).json")
        try? fileManager.removeItem(at: tsvURL)
        try? fileManager.removeItem(at: configURL)
    }

    func deleteAllFunds() throws {
        let dir = fundsDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Delete all funds belonging to test platforms (coinbasetest, robinhoodtest, demo, etc.)
    func deleteTestFunds() throws -> Int {
        let funds = readAllFunds()
        var deleted = 0
        for fund in funds where isTestPlatform(fund.platform) {
            try deleteFund(id: fund.id)
            deleted += 1
        }
        return deleted
    }

    /// Count how many test funds currently exist
    func testFundCount() -> Int {
        readAllFunds().filter { isTestPlatform($0.platform) }.count
    }

    /// Load bundled test data (5 funds matching the web app's test dataset)
    func loadTestData() throws -> Int {
        let testFundIds = [
            "coinbasetest-btc",
            "coinbasetest-cash",
            "robinhoodtest-tqqq",
            "robinhoodtest-spxl",
            "robinhoodtest-cash"
        ]

        // Remove existing test funds first
        _ = try deleteTestFunds()

        var loaded = 0
        for fundId in testFundIds {
            guard let jsonURL = Bundle.main.url(forResource: fundId, withExtension: "json"),
                  let tsvURL = Bundle.main.url(forResource: fundId, withExtension: "tsv") else {
                continue
            }

            let destJSON = fundsDirectory.appendingPathComponent("\(fundId).json")
            let destTSV = fundsDirectory.appendingPathComponent("\(fundId).tsv")

            try? fileManager.removeItem(at: destJSON)
            try? fileManager.removeItem(at: destTSV)

            try fileManager.copyItem(at: jsonURL, to: destJSON)
            try fileManager.copyItem(at: tsvURL, to: destTSV)
            loaded += 1
        }
        return loaded
    }

    // MARK: - Import

    func importFromDirectory(_ sourceDir: URL) throws -> Int {
        let fm = fileManager
        guard let files = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else {
            return 0
        }

        let tsvFiles = files.filter { $0.pathExtension == "tsv" }
        var imported = 0

        for tsvFile in tsvFiles {
            let baseName = tsvFile.deletingPathExtension().lastPathComponent
            let jsonFile = sourceDir.appendingPathComponent("\(baseName).json")
            guard fm.fileExists(atPath: jsonFile.path) else { continue }

            let destTSV = fundsDirectory.appendingPathComponent("\(baseName).tsv")
            let destJSON = fundsDirectory.appendingPathComponent("\(baseName).json")

            // Remove existing if present
            try? fm.removeItem(at: destTSV)
            try? fm.removeItem(at: destJSON)

            try fm.copyItem(at: tsvFile, to: destTSV)
            try fm.copyItem(at: jsonFile, to: destJSON)
            imported += 1
        }

        return imported
    }

    // MARK: - Backup JSON Import

    func importFromBackupJSON(_ jsonURL: URL) throws -> Int {
        // Ensure funds directory exists
        try? fileManager.createDirectory(at: fundsDirectory, withIntermediateDirectories: true)

        let data = try Data(contentsOf: jsonURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fundsArray = json["funds"] as? [[String: Any]] else {
            throw NSError(domain: "FundStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid backup format: missing 'funds' array"])
        }

        var imported = 0
        for fundDict in fundsArray {
            guard let id = fundDict["id"] as? String,
                  let platform = fundDict["platform"] as? String,
                  let ticker = fundDict["ticker"] as? String,
                  let configDict = fundDict["config"] as? [String: Any],
                  let entriesArray = fundDict["entries"] as? [[String: Any]] else {
                continue
            }

            // Skip test/demo funds
            if isTestPlatform(platform) {
                continue
            }

            do {
                // Build config JSON with platform/ticker metadata
                var configWithMeta = configDict
                configWithMeta["__platform"] = platform
                configWithMeta["__ticker"] = ticker

                let configData = try JSONSerialization.data(withJSONObject: configWithMeta, options: [.prettyPrinted, .sortedKeys])
                let configURL = fundsDirectory.appendingPathComponent("\(id).json")
                try configData.write(to: configURL)

            // Build TSV from entries
            var lines = [["date", "value", "cash", "action", "amount", "shares", "price", "dividend", "expense", "cash_interest", "fund_size", "margin_available", "margin_borrowed", "margin_expense", "notes", "contracts", "entry_price", "liquidation_price", "unrealized_pnl", "margin_locked", "fee", "margin"].joined(separator: "\t")]

            for entry in entriesArray {
                let cols: [String] = [
                    entry["date"] as? String ?? "",
                    formatNum(entry["value"]),
                    formatNum(entry["cash"]),
                    entry["action"] as? String ?? "",
                    formatNum(entry["amount"]),
                    formatNum(entry["shares"]),
                    formatNum(entry["price"]),
                    formatNum(entry["dividend"]),
                    formatNum(entry["expense"]),
                    formatNum(entry["cash_interest"]),
                    formatNum(entry["fund_size"]),
                    formatNum(entry["margin_available"]),
                    formatNum(entry["margin_borrowed"]),
                    formatNum(entry["margin_expense"]),
                    (entry["notes"] as? String ?? "").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n"),
                    formatNum(entry["contracts"]),
                    formatNum(entry["entry_price"]),
                    formatNum(entry["liquidation_price"]),
                    formatNum(entry["unrealized_pnl"]),
                    formatNum(entry["margin_locked"]),
                    formatNum(entry["fee"]),
                    formatNum(entry["margin"])
                ]
                lines.append(cols.joined(separator: "\t"))
            }

                let tsv = lines.joined(separator: "\n") + "\n"
                let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
                try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
                imported += 1
            } catch {
                // Skip this fund, continue with others
                continue
            }
        }

        return imported
    }

    private func formatNum(_ value: Any?) -> String {
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

    func exportToDirectory(_ destDir: URL) throws -> Int {
        let fm = fileManager
        guard let files = try? fm.contentsOfDirectory(at: fundsDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }

        let tsvFiles = files.filter { $0.pathExtension == "tsv" }
        var exported = 0

        for tsvFile in tsvFiles {
            let baseName = tsvFile.deletingPathExtension().lastPathComponent
            let jsonFile = fundsDirectory.appendingPathComponent("\(baseName).json")

            let destTSV = destDir.appendingPathComponent("\(baseName).tsv")
            let destJSON = destDir.appendingPathComponent("\(baseName).json")

            try? fm.removeItem(at: destTSV)
            try fm.copyItem(at: tsvFile, to: destTSV)

            if fm.fileExists(atPath: jsonFile.path) {
                try? fm.removeItem(at: destJSON)
                try fm.copyItem(at: jsonFile, to: destJSON)
            }
            exported += 1
        }
        return exported
    }

    /// Export all funds to a single backup JSON file, returning its URL.
    func exportToBackupJSON() throws -> URL {
        let funds = readAllFunds()
        var fundsArray: [[String: Any]] = []

        for fund in funds {
            var configDict: [String: Any] = [:]
            let configData = try JSONEncoder.pretty.encode(fund.config)
            if let parsed = try JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                configDict = parsed
            }

            let entriesArray: [[String: Any]] = fund.entries.map { entry in
                var d: [String: Any] = ["date": entry.date, "value": entry.value]
                if let v = entry.cash { d["cash"] = v }
                if let v = entry.action { d["action"] = v.rawValue }
                if let v = entry.amount { d["amount"] = v }
                if let v = entry.shares { d["shares"] = v }
                if let v = entry.price { d["price"] = v }
                if let v = entry.dividend { d["dividend"] = v }
                if let v = entry.expense { d["expense"] = v }
                if let v = entry.cash_interest { d["cash_interest"] = v }
                if let v = entry.fund_size { d["fund_size"] = v }
                if let v = entry.margin_available { d["margin_available"] = v }
                if let v = entry.margin_borrowed { d["margin_borrowed"] = v }
                if let v = entry.margin_expense { d["margin_expense"] = v }
                if let v = entry.notes, !v.isEmpty { d["notes"] = v }
                if let v = entry.contracts { d["contracts"] = v }
                if let v = entry.entry_price { d["entry_price"] = v }
                if let v = entry.liquidation_price { d["liquidation_price"] = v }
                if let v = entry.unrealized_pnl { d["unrealized_pnl"] = v }
                if let v = entry.margin_locked { d["margin_locked"] = v }
                if let v = entry.fee { d["fee"] = v }
                if let v = entry.margin { d["margin"] = v }
                return d
            }

            fundsArray.append([
                "id": fund.id,
                "platform": fund.platform,
                "ticker": fund.ticker,
                "config": configDict,
                "entries": entriesArray
            ])
        }

        let backup: [String: Any] = [
            "version": 1,
            "exported": ISO8601DateFormatter().string(from: Date()),
            "funds": fundsArray
        ]

        let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "escapemint-backup-\(df.string(from: Date())).json"

        let tempDir = FileManager.default.temporaryDirectory
        let backupURL = tempDir.appendingPathComponent(filename)
        try data.write(to: backupURL)
        return backupURL
    }

    struct DataStats {
        let fundCount: Int
        let totalBytes: Int
        var formattedSize: String {
            if totalBytes < 1024 { return "\(totalBytes) B" }
            if totalBytes < 1024 * 1024 { return String(format: "%.1f KB", Double(totalBytes) / 1024) }
            return String(format: "%.1f MB", Double(totalBytes) / 1024 / 1024)
        }
    }

    func dataStats() -> DataStats {
        let dir = fundsDirectory
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return DataStats(fundCount: 0, totalBytes: 0)
        }
        let tsvCount = files.filter { $0.pathExtension == "tsv" }.count
        let totalBytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return DataStats(fundCount: tsvCount, totalBytes: totalBytes)
    }
}

// MARK: - TSV Parsing

private let entryHeaders = ["date", "value", "cash", "action", "amount", "shares", "price", "dividend", "expense", "cash_interest", "fund_size", "margin_available", "margin_borrowed", "margin_expense", "notes", "contracts", "entry_price", "liquidation_price", "unrealized_pnl", "margin_locked", "fee", "margin"]

func parseTSV(_ content: String) -> [FundEntry] {
    let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count > 1 else { return [] }

    let headers = lines[0].split(separator: "\t").map(String.init)
    return lines.dropFirst().compactMap { line in
        parseEntry(String(line), headers: headers)
    }
}

func parseEntry(_ line: String, headers: [String]) -> FundEntry {
    let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    var entry = FundEntry(date: "", value: 0)

    for (i, header) in headers.enumerated() {
        let val = i < values.count ? values[i] : ""
        if val.isEmpty { continue }

        switch header {
        case "date": entry.date = val
        case "value": entry.value = Double(val) ?? 0
        case "cash": entry.cash = Double(val)
        case "action": entry.action = FundAction(rawValue: val)
        case "amount": entry.amount = Double(val)
        case "shares": entry.shares = Double(val)
        case "price": entry.price = Double(val)
        case "dividend": entry.dividend = Double(val)
        case "expense": entry.expense = Double(val)
        case "cash_interest": entry.cash_interest = Double(val)
        case "fund_size": entry.fund_size = Double(val)
        case "margin_available": entry.margin_available = Double(val)
        case "margin_borrowed": entry.margin_borrowed = Double(val)
        case "margin_expense": entry.margin_expense = Double(val)
        case "notes": entry.notes = val.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n")
        case "contracts": entry.contracts = Double(val)
        case "entry_price": entry.entry_price = Double(val)
        case "liquidation_price": entry.liquidation_price = Double(val)
        case "unrealized_pnl": entry.unrealized_pnl = Double(val)
        case "margin_locked": entry.margin_locked = Double(val)
        case "fee": entry.fee = Double(val)
        case "margin": entry.margin = Double(val)
        default: break
        }
    }
    return entry
}

func optStr(_ val: Double?) -> String { val.map { String($0) } ?? "" }

func serializeEntry(_ entry: FundEntry) -> String {
    var parts: [String] = []
    parts.append(entry.date)
    parts.append(String(entry.value))
    parts.append(optStr(entry.cash))
    parts.append(entry.action?.rawValue ?? "")
    parts.append(optStr(entry.amount))
    parts.append(optStr(entry.shares))
    parts.append(optStr(entry.price))
    parts.append(optStr(entry.dividend))
    parts.append(optStr(entry.expense))
    parts.append(optStr(entry.cash_interest))
    parts.append(optStr(entry.fund_size))
    parts.append(optStr(entry.margin_available))
    parts.append(optStr(entry.margin_borrowed))
    parts.append(optStr(entry.margin_expense))
    let notes = (entry.notes ?? "").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
    parts.append(notes)
    parts.append(optStr(entry.contracts))
    parts.append(optStr(entry.entry_price))
    parts.append(optStr(entry.liquidation_price))
    parts.append(optStr(entry.unrealized_pnl))
    parts.append(optStr(entry.margin_locked))
    parts.append(optStr(entry.fee))
    parts.append(optStr(entry.margin))
    return parts.joined(separator: "\t")
}

func buildTSV(_ entries: [FundEntry]) -> String {
    var lines = [entryHeaders.joined(separator: "\t")]
    for entry in entries {
        lines.append(serializeEntry(entry))
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Check if a platform is a test/demo platform
func isTestPlatform(_ platform: String) -> Bool {
    let p = platform.lowercased()
    return p.hasSuffix("test") || p.hasPrefix("test") || p.hasPrefix("demo")
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
