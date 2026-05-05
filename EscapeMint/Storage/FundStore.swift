import Foundation
import os

actor FundStore {
    static let shared = FundStore()

    private let fileManager = FileManager.default
    private static let iCloudContainerId = "iCloud.net.shadowpuppet.EscapeMint"
    private static let logger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "FundStore")
    private static let backupDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        return df
    }()

    // Thread-safe directory state. `fundsDirectory` and `isICloud` may flip exactly once
    // during `retryICloudIfNeeded()`, and the flip happens inside the actor. But view
    // bodies and nonisolated readers access them off-actor, so the underlying storage is
    // guarded by a lock rather than `nonisolated(unsafe)`. Computed-property accessors
    // keep the original call-site syntax unchanged.
    private struct DirectoryState: Sendable {
        var fundsDirectory: URL
        var isICloud: Bool
    }
    private static let stateLock = OSAllocatedUnfairLock<DirectoryState?>(initialState: nil)

    nonisolated var fundsDirectory: URL {
        // force-unwrap is safe: `init` sets state before the actor is ever accessible
        Self.stateLock.withLock { $0! }.fundsDirectory
    }
    nonisolated var isICloud: Bool {
        Self.stateLock.withLock { $0! }.isICloud
    }
    fileprivate static var currentFundsDirectory: URL {
        stateLock.withLock { $0! }.fundsDirectory
    }

    private init() {
        let fm = FileManager.default

        // Try iCloud first, verify it's actually accessible, fall back to local
        let resolvedDir: URL
        let resolvedICloud: Bool

        // When loading test data (screenshots), skip iCloud to avoid sync race conditions
        let skipICloud = CommandLine.arguments.contains("-loadTestData")

        if !skipICloud,
           let iCloudURL = fm.url(forUbiquityContainerIdentifier: Self.iCloudContainerId) {
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
                Self.logger.info("☁️ using iCloud: \(funds.path, privacy: .public)")
            } else if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                let local = docs.appendingPathComponent("funds")
                try? fm.createDirectory(at: local, withIntermediateDirectories: true)
                resolvedDir = local
                resolvedICloud = false
                Self.logger.warning("⚠️ iCloud container exists but inaccessible, using local")
            } else {
                Self.logger.warning("⚠️ documentDirectory unavailable, using temp directory")
                let local = fm.temporaryDirectory.appendingPathComponent("funds")
                try? fm.createDirectory(at: local, withIntermediateDirectories: true)
                resolvedDir = local
                resolvedICloud = false
            }
        } else if !skipICloud {
            // iCloud URL returned nil — may be temporarily unavailable (e.g. after reboot)
            Self.logger.info("⚠️ iCloud unavailable at init, will retry during load")
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                let funds = docs.appendingPathComponent("funds")
                try? fm.createDirectory(at: funds, withIntermediateDirectories: true)
                resolvedDir = funds
                resolvedICloud = false
            } else {
                let funds = fm.temporaryDirectory.appendingPathComponent("funds")
                try? fm.createDirectory(at: funds, withIntermediateDirectories: true)
                resolvedDir = funds
                resolvedICloud = false
            }
        } else {
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                let funds = docs.appendingPathComponent("funds")
                try? fm.createDirectory(at: funds, withIntermediateDirectories: true)
                resolvedDir = funds
            } else {
                let funds = fm.temporaryDirectory.appendingPathComponent("funds")
                try? fm.createDirectory(at: funds, withIntermediateDirectories: true)
                resolvedDir = funds
            }
            resolvedICloud = false
        }

        Self.stateLock.withLock { state in
            state = DirectoryState(fundsDirectory: resolvedDir, isICloud: resolvedICloud)
        }
    }

    /// Retry iCloud resolution if it wasn't available at init (e.g. after system reboot).
    /// Called during the loading screen before any funds are read.
    /// Returns true if iCloud became available and the funds directory was switched.
    func hasICloudAccount() -> Bool {
        fileManager.ubiquityIdentityToken != nil
    }

    func retryICloudIfNeeded(maxAttempts: Int = 5, delay: Duration = .seconds(1)) async -> Bool {
        guard !isICloud else { return false }

        let fm = FileManager.default

        // If no iCloud account is signed in at all, don't waste time retrying
        guard fm.ubiquityIdentityToken != nil else {
            Self.logger.info("☁️ no iCloud account, skipping retry")
            return false
        }

        let attemptLimit = max(1, maxAttempts)
        for attempt in 1...attemptLimit {
            Self.logger.info("☁️ iCloud retry \(attempt)/\(attemptLimit)")
            try? await Task.sleep(for: delay)

            guard let iCloudURL = fm.url(forUbiquityContainerIdentifier: Self.iCloudContainerId) else {
                continue
            }
            let funds = iCloudURL.appendingPathComponent("Documents/funds")
            do {
                try fm.createDirectory(at: funds, withIntermediateDirectories: true)
                _ = try fm.contentsOfDirectory(at: funds, includingPropertiesForKeys: nil)
                Self.logger.info("☁️ iCloud recovered on attempt \(attempt)")
                Self.stateLock.withLock { state in
                    state = DirectoryState(fundsDirectory: funds, isICloud: true)
                }
                return true
            } catch {
                continue
            }
        }
        Self.logger.warning("☁️ iCloud unavailable after \(attemptLimit) retries, using local storage")
        return false
    }

    /// Migrate local funds to iCloud if iCloud became available
    func migrateToICloudIfNeeded() {
        guard isICloud else { return }
        let fm = fileManager
        guard let localDocs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
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

    /// Read only JSON configs (no TSV entries) — returns FundData with empty entries for instant sidebar/nav.
    nonisolated func readAllFundConfigs() -> [FundData] {
        let dir = Self.currentFundsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { readFundConfig(jsonURL: $0) }
    }

    /// Read entries for a single fund by its id — nonisolated for true parallel I/O.
    nonisolated func readFundEntries(id: String) -> [FundEntry] {
        let tsvURL = Self.currentFundsDirectory.appendingPathComponent("\(id).tsv")
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

        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: configURL.path)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tsvURL.path)
        #endif
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
        // Re-apply file protection after atomic write (atomic creates a new file via rename)
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tsvURL.path)
        #endif
    }

    func updateConfig(fundId: String, config: FundConfig) throws {
        let configURL = fundsDirectory.appendingPathComponent("\(fundId).json")
        guard fileManager.fileExists(atPath: configURL.path) else { return }

        let existing = try Data(contentsOf: configURL)
        let existingConfig = try JSONDecoder().decode(FundConfig.self, from: existing)

        var updated = config
        updated.platform = existingConfig.platform
        updated.ticker = existingConfig.ticker
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(to: configURL, options: .atomic)
        // Re-apply file protection after atomic write — non-atomic in-place overwrites
        // on older iOS can strip the protection attribute.
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: configURL.path)
        #endif
    }

    func deleteFund(id: String) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")
        let configURL = fundsDirectory.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: tsvURL.path) {
            try fileManager.removeItem(at: tsvURL)
        }
        if fileManager.fileExists(atPath: configURL.path) {
            try fileManager.removeItem(at: configURL)
        }
    }

    func deleteAllFunds() throws {
        let dir = fundsDirectory
        let files = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for file in files {
            try fileManager.removeItem(at: file)
        }

        // When using iCloud, also clear the local Documents/funds/ directory
        // to prevent migrateToICloudIfNeeded() from restoring deleted data on next launch
        if isICloud, let localDocs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localFunds = localDocs.appendingPathComponent("funds")
            if let localFiles = try? fileManager.contentsOfDirectory(at: localFunds, includingPropertiesForKeys: nil) {
                for file in localFiles {
                    try fileManager.removeItem(at: file)
                }
            }
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
        // Propagate enumeration errors — previously `try?` silently swallowed a security-scope
        // expiry or permission-denied failure, returning 0 with no user-facing indication.
        let files = try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)

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

        let safeFundIdPattern = /^[a-zA-Z0-9._-]+$/
        var imported = 0
        for fundDict in fundsArray {
            guard let id = fundDict["id"] as? String,
                  let platform = fundDict["platform"] as? String,
                  let ticker = fundDict["ticker"] as? String,
                  let configDict = fundDict["config"] as? [String: Any],
                  let entriesArray = fundDict["entries"] as? [[String: Any]] else {
                continue
            }

            // Validate fund ID contains only safe characters for file paths
            guard id.wholeMatch(of: safeFundIdPattern) != nil else {
                Self.logger.warning("skipping fund with unsafe id: \(id, privacy: .private)")
                continue
            }

            // Skip test/demo funds
            if isTestPlatform(platform) {
                continue
            }

            let configURL = fundsDirectory.appendingPathComponent("\(id).json")
            let tsvURL = fundsDirectory.appendingPathComponent("\(id).tsv")

            do {
                var configWithMeta = configDict
                configWithMeta["__platform"] = platform
                configWithMeta["__ticker"] = ticker

                let configData = try JSONSerialization.data(withJSONObject: configWithMeta, options: [.prettyPrinted, .sortedKeys])
                try configData.write(to: configURL, options: .atomic)
                #if os(iOS)
                try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: configURL.path)
                #endif

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
                try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
                #if os(iOS)
                try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: tsvURL.path)
                #endif
                imported += 1
            } catch {
                // Roll back partial state: if the config write succeeded but the TSV
                // write (or any later step) failed, an orphan .json would be left on
                // disk, presenting as a ghost fund with no entries. Remove both files
                // so the user sees a clean "N of M imported" count.
                try? fileManager.removeItem(at: configURL)
                try? fileManager.removeItem(at: tsvURL)
                Self.logger.warning("skipping fund '\(id, privacy: .private)' during backup import: \(error.localizedDescription, privacy: .public)")
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
            "version": "1.0.0",
            "backup_date": ISO8601DateFormatter().string(from: Date()),
            "funds": fundsArray,
            "platforms": NSNull(),
            "totals_snapshot": NSNull(),
            "scrape_archives": [String: Any]()
        ]

        let data = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])

        let filename = "escapemint-backup-\(Self.backupDateFormatter.string(from: Date())).json"

        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("escapemint-export")
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        // Clean up any previous export files
        if let oldFiles = try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil) {
            for f in oldFiles { try? FileManager.default.removeItem(at: f) }
        }
        let backupURL = exportDir.appendingPathComponent(filename)
        try data.write(to: backupURL)
        return backupURL
    }

    /// Create a timestamped backup of a single fund before a destructive operation.
    /// Returns the backup directory URL for the toast message.
    func backupFund(id: String) throws -> URL {
        let fm = fileManager
        let backupDir = fundsDirectory.deletingLastPathComponent().appendingPathComponent("backups")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let timestamp = Self.backupDateFormatter.string(from: Date())
        let fundBackupDir = backupDir.appendingPathComponent("\(id)_\(timestamp)")
        try fm.createDirectory(at: fundBackupDir, withIntermediateDirectories: true)

        let tsvSrc = fundsDirectory.appendingPathComponent("\(id).tsv")
        let jsonSrc = fundsDirectory.appendingPathComponent("\(id).json")

        if fm.fileExists(atPath: tsvSrc.path) {
            try fm.copyItem(at: tsvSrc, to: fundBackupDir.appendingPathComponent("\(id).tsv"))
        }
        if fm.fileExists(atPath: jsonSrc.path) {
            try fm.copyItem(at: jsonSrc, to: fundBackupDir.appendingPathComponent("\(id).json"))
        }
        return fundBackupDir
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

/// Round a currency value to 2 decimal places to avoid IEEE 754 artifacts (e.g. 45.55000000000001)
private func roundCurrency(_ val: Double) -> Double { (val * 100).rounded() / 100 }
private func roundCurrency(_ val: Double?) -> Double? { val.map { roundCurrency($0) } }
/// Shares/contracts can be fractional (crypto) — round to 8 decimals
private func roundQuantity(_ val: Double?) -> Double? { val.map { ($0 * 1e8).rounded() / 1e8 } }
/// Prices can have up to 8 decimals for low-price crypto (e.g. DOGE $0.09424)
private func roundPrice(_ val: Double?) -> Double? { val.map { ($0 * 1e8).rounded() / 1e8 } }

func parseEntry(_ line: String, headers: [String]) -> FundEntry {
    let values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    var entry = FundEntry(date: "", value: 0)

    for (i, header) in headers.enumerated() {
        let val = i < values.count ? values[i] : ""
        if val.isEmpty { continue }

        switch header {
        case "date": entry.date = val
        case "value": entry.value = roundCurrency(Double(val) ?? 0)
        case "cash": entry.cash = roundCurrency(Double(val))
        case "action": entry.action = FundAction(rawValue: val)
        case "amount": entry.amount = roundCurrency(Double(val))
        case "shares": entry.shares = roundQuantity(Double(val))
        case "price": entry.price = roundPrice(Double(val))
        case "dividend": entry.dividend = roundCurrency(Double(val))
        case "expense": entry.expense = roundCurrency(Double(val))
        case "cash_interest": entry.cash_interest = roundCurrency(Double(val))
        case "fund_size": entry.fund_size = roundCurrency(Double(val))
        case "margin_available": entry.margin_available = roundCurrency(Double(val))
        case "margin_borrowed": entry.margin_borrowed = roundCurrency(Double(val))
        case "margin_expense": entry.margin_expense = roundCurrency(Double(val))
        case "notes": entry.notes = val.replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\n", with: "\n")
        case "contracts": entry.contracts = roundQuantity(Double(val))
        case "entry_price": entry.entry_price = roundPrice(Double(val))
        case "liquidation_price": entry.liquidation_price = roundPrice(Double(val))
        case "unrealized_pnl": entry.unrealized_pnl = roundCurrency(Double(val))
        case "margin_locked": entry.margin_locked = roundCurrency(Double(val))
        case "fee": entry.fee = roundCurrency(Double(val))
        case "margin": entry.margin = roundCurrency(Double(val))
        default: break
        }
    }
    return entry
}

/// Format a Double for TSV output, stripping trailing zeros (e.g. 245.55 not 245.55000000000001)
private func fmtCurrency(_ val: Double) -> String {
    let rounded = roundCurrency(val)
    return rounded == rounded.rounded(.down) ? String(format: "%.0f", rounded) : String(format: "%.2f", rounded)
}
private func fmtCurrency(_ val: Double?) -> String { val.map { fmtCurrency($0) } ?? "" }
/// Format a price for TSV — preserves up to 8 decimals for low-price assets
private func fmtPrice(_ val: Double?) -> String { fmtQuantity(val) }
private func fmtQuantity(_ val: Double?) -> String {
    guard let v = val else { return "" }
    let rounded = (v * 1e8).rounded() / 1e8
    // Strip trailing zeros: use %g-style but cap at 8 decimals
    if rounded == rounded.rounded(.down) { return String(format: "%.0f", rounded) }
    let s = String(format: "%.8f", rounded)
    // Trim trailing zeros after decimal
    var end = s.endIndex
    while end > s.startIndex && s[s.index(before: end)] == "0" { end = s.index(before: end) }
    if end > s.startIndex && s[s.index(before: end)] == "." { end = s.index(before: end) }
    return String(s[s.startIndex..<end])
}

func serializeEntry(_ entry: FundEntry) -> String {
    var parts: [String] = []
    parts.append(entry.date)
    parts.append(fmtCurrency(entry.value))
    parts.append(fmtCurrency(entry.cash))
    parts.append(entry.action?.rawValue ?? "")
    parts.append(fmtCurrency(entry.amount))
    parts.append(fmtQuantity(entry.shares))
    parts.append(fmtPrice(entry.price))
    parts.append(fmtCurrency(entry.dividend))
    parts.append(fmtCurrency(entry.expense))
    parts.append(fmtCurrency(entry.cash_interest))
    parts.append(fmtCurrency(entry.fund_size))
    parts.append(fmtCurrency(entry.margin_available))
    parts.append(fmtCurrency(entry.margin_borrowed))
    parts.append(fmtCurrency(entry.margin_expense))
    let notes = (entry.notes ?? "").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
    parts.append(notes)
    parts.append(fmtQuantity(entry.contracts))
    parts.append(fmtPrice(entry.entry_price))
    parts.append(fmtPrice(entry.liquidation_price))
    parts.append(fmtCurrency(entry.unrealized_pnl))
    parts.append(fmtCurrency(entry.margin_locked))
    parts.append(fmtCurrency(entry.fee))
    parts.append(fmtCurrency(entry.margin))
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
