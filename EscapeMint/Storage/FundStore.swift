import Foundation
import os

/// Type-safe model of the single-file backup JSON shared with the web app.
///
/// The on-disk shape must stay byte-compatible with the web app's `BackupData`
/// (`packages/storage/src/backup.ts`): `version` ("1.0.0"), `backup_date` (ISO-8601),
/// `funds`, `platforms` (null), `totals_snapshot` (null), `scrape_archives` ({}).
/// The web app's `normalizeBackupData` also tolerates the older `{ version: 1, exported }`
/// shape, but we always write the canonical string-versioned form.
struct BackupDocument: Codable {
    var version: String
    var backup_date: String
    var funds: [BackupFund]
    /// Always emitted as JSON `null`/`{}` — the native app does not manage these web-only
    /// sections, but the keys are written so the on-disk file stays byte-compatible with the
    /// web app's exports. Encoded explicitly (never omitted) to preserve key presence.
    var platforms: JSONNull
    var totals_snapshot: JSONNull
    var scrape_archives: [String: JSONNull]

    init(funds: [BackupFund], backupDate: String) {
        self.version = "1.0.0"
        self.backup_date = backupDate
        self.funds = funds
        self.platforms = JSONNull()
        self.totals_snapshot = JSONNull()
        self.scrape_archives = [:]
    }

    // Decoding tolerates the older `{ version: 1, exported }` shape and absent
    // platforms/totals/archives (mirrors the web app's `normalizeBackupData`).
    enum CodingKeys: String, CodingKey {
        case version, backup_date, exported, funds, platforms, totals_snapshot, scrape_archives
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // version may be a string ("1.0.0") or the legacy numeric 1.
        if let v = try? c.decode(String.self, forKey: .version) {
            version = v
        } else if let n = try? c.decode(Int.self, forKey: .version) {
            version = n == 1 ? "1.0.0" : String(n)
        } else {
            version = "1.0.0"
        }
        backup_date = (try? c.decode(String.self, forKey: .backup_date))
            ?? (try? c.decode(String.self, forKey: .exported))
            ?? ""
        funds = try c.decode([BackupFund].self, forKey: .funds)
        platforms = JSONNull()
        totals_snapshot = JSONNull()
        scrape_archives = [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(backup_date, forKey: .backup_date)
        try c.encode(funds, forKey: .funds)
        try c.encode(platforms, forKey: .platforms)
        try c.encode(totals_snapshot, forKey: .totals_snapshot)
        try c.encode(scrape_archives, forKey: .scrape_archives)
    }
}

/// A single fund inside a backup. `config` carries the same `__`-prefixed metadata keys
/// as the per-fund on-disk JSON (see `FundConfig.CodingKeys`), so it round-trips through
/// `FundConfig` without a lossy `[String: Any]` detour.
struct BackupFund: Codable {
    var id: String
    var platform: String
    var ticker: String
    var config: FundConfig
    var entries: [FundEntry]
}

/// Encodes as JSON `null`, decodes from `null` or absent. Lets `BackupDocument` emit the
/// web-app's `platforms: null` / `totals_snapshot: null` keys without an `Any` payload.
struct JSONNull: Codable {
    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard container.decodeNil() else {
            throw DecodingError.typeMismatch(
                JSONNull.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected null")
            )
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

/// The disk-I/O surface `FundDataStore` depends on, extracted so the in-memory
/// store can be unit-tested against a fake instead of the real `FundStore.shared`
/// singleton (issue #72, complements the directory-resolver seam from #47).
///
/// Covers exactly the members `FundDataStore` invokes: the iCloud lifecycle, the
/// load/reload reads, and every mutation it persists. `nonisolated` members mirror
/// `FundStore`'s nonisolated declarations so they can be called from the detached
/// load tasks (`isICloud`, `readAllFundConfigs`, `readFundEntries`) without a hop
/// back onto the actor. The protocol is `Sendable` so `FundDataStore` (a
/// `@MainActor` type) can hold it and capture it in those detached tasks.
protocol FundStoreProtocol: Sendable {
    nonisolated var isICloud: Bool { get }

    func hasICloudAccount() async -> Bool
    func retryICloudIfNeeded(maxAttempts: Int, delay: Duration) async -> Bool
    func migrateToICloudIfNeeded() async

    nonisolated func readAllFundConfigs() -> [FundData]
    nonisolated func readFundEntries(id: String) -> [FundEntry]
    func readAllFunds() async -> [FundData]

    func writeFund(_ fund: FundData) async throws
    func appendEntry(fundId: String, entry: FundEntry) async throws
    func replaceEntries(fundId: String, entries: [FundEntry]) async throws
    @discardableResult
    func updateConfig(fundId: String, config: FundConfig) async throws -> Bool
    @discardableResult
    func updateHistoryCache(fundId: String, cache: FundHistoryCache?) async throws -> Bool
    func deleteFund(id: String) async throws
    func deletePlatform(named platform: String) async throws -> Int
    func backupFund(id: String) async throws -> URL

    // Bulk import/export and test-data operations the FundDataStore facade
    // delegates to (views call FundDataStore, which routes through this store).
    func dataStats() async -> FundStore.DataStats
    func testFundCount() async -> Int
    func importFromDirectory(_ sourceDir: URL) async throws -> Int
    func backupJSONFundCount(_ jsonURL: URL) async throws -> Int
    func importFromBackupJSON(_ jsonURL: URL) async throws -> Int
    func exportToBackupJSON() async throws -> URL
    func exportToDocuments() async throws -> URL
    func loadTestData() async throws -> Int
    func deleteTestFunds() async throws -> Int
    func deleteAllFunds() async throws
}

extension FundStore: FundStoreProtocol {}

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
    // Internal (not private) so storage-fallback tests can assert the resolved branch.
    struct DirectoryState: Sendable {
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
    nonisolated static var shouldUseLocalStorageOnly: Bool {
        let args = CommandLine.arguments
        if args.contains("-loadTestData") || args.contains("-skipICloud") {
            return true
        }
        #if targetEnvironment(simulator)
        return !args.contains("-useICloudInSimulator")
        #else
        return false
        #endif
    }
    fileprivate static var currentFundsDirectory: URL {
        stateLock.withLock { $0! }.fundsDirectory
    }

    /// Create a directory, logging a warning on failure instead of silently swallowing it.
    /// Control flow is unchanged from the previous `try?` calls — this only makes the
    /// failure observable (the caller still proceeds with the resolved directory).
    private static func createDirectoryLoggingFailure(_ fm: FileManager, at url: URL) {
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.warning("⚠️ failed to create directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolve the funds directory and whether it lives in iCloud.
    ///
    /// Pure with respect to its inputs — it does file I/O via `fm` and reads the iCloud
    /// container URL via `ubiquityURLProvider`, but takes no global state — so tests can
    /// drive every branch (iCloud works / container present-but-inaccessible / URL nil /
    /// iCloud skipped) by injecting a temp FileManager and a fake provider. The production
    /// `init()` wires in the real `FileManager.url(forUbiquityContainerIdentifier:)`.
    ///
    /// Branch behavior (gotcha catalogue #4): a non-nil ubiquity URL is NOT proof the
    /// container is usable, so we verify accessibility with `createDirectory` THEN
    /// `contentsOfDirectory` in a do/catch and fall back to local Documents (never temp)
    /// when that verification fails. Temp is only ever used as a last resort when even the
    /// local Documents directory is unavailable.
    static func resolveDirectoryState(
        fm: FileManager,
        skipICloud: Bool,
        ubiquityURLProvider: () -> URL?
    ) -> DirectoryState {
        // Local fallback: prefer Documents/funds, drop to temp/funds only if Documents
        // is unavailable. Shared by every non-iCloud branch.
        func localFallback() -> URL {
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                let funds = docs.appendingPathComponent("funds")
                createDirectoryLoggingFailure(fm, at: funds)
                return funds
            }
            logger.warning("⚠️ documentDirectory unavailable, using temp directory")
            let funds = fm.temporaryDirectory.appendingPathComponent("funds")
            createDirectoryLoggingFailure(fm, at: funds)
            return funds
        }

        guard !skipICloud else {
            return DirectoryState(fundsDirectory: localFallback(), isICloud: false)
        }

        guard let iCloudURL = ubiquityURLProvider() else {
            // iCloud URL returned nil — may be temporarily unavailable (e.g. after reboot).
            // A deferred recovery retry runs once the UI is up.
            logger.info("⚠️ iCloud unavailable at init, will retry during load")
            return DirectoryState(fundsDirectory: localFallback(), isICloud: false)
        }

        let funds = iCloudURL.appendingPathComponent("Documents/funds")
        var iCloudWorks = false
        do {
            try fm.createDirectory(at: funds, withIntermediateDirectories: true)
            // Critical (gotcha #4): a non-nil ubiquity URL only means the entitlement is
            // configured, not that the directory is usable. Verify by actually listing it.
            _ = try fm.contentsOfDirectory(at: funds, includingPropertiesForKeys: nil)
            iCloudWorks = true
        } catch {
            // iCloud container exists but isn't accessible (e.g. permission denied)
            logger.warning("⚠️ iCloud container present but inaccessible: \(error.localizedDescription, privacy: .public)")
        }
        if iCloudWorks {
            logger.info("☁️ using iCloud: \(funds.path, privacy: .public)")
            return DirectoryState(fundsDirectory: funds, isICloud: true)
        }
        logger.warning("⚠️ iCloud container exists but inaccessible, using local")
        return DirectoryState(fundsDirectory: localFallback(), isICloud: false)
    }

    private init() {
        let fm = FileManager.default
        // Simulator iCloud container directory creation can hang indefinitely.
        // Use local storage for normal simulator runs; pass -useICloudInSimulator
        // when intentionally testing iCloud behavior.
        let state = Self.resolveDirectoryState(
            fm: fm,
            skipICloud: Self.shouldUseLocalStorageOnly,
            ubiquityURLProvider: { fm.url(forUbiquityContainerIdentifier: Self.iCloudContainerId) }
        )
        Self.stateLock.withLock { $0 = state }
    }

    /// Retry iCloud resolution if it wasn't available at init (e.g. after system reboot).
    /// Called during the loading screen before any funds are read.
    /// Returns true if iCloud became available and the funds directory was switched.
    func hasICloudAccount() -> Bool {
        guard !Self.shouldUseLocalStorageOnly else { return false }
        return fileManager.ubiquityIdentityToken != nil
    }

    func retryICloudIfNeeded(maxAttempts: Int = 5, delay: Duration = .seconds(1)) async -> Bool {
        guard !isICloud else { return false }
        guard !Self.shouldUseLocalStorageOnly else {
            Self.logger.info("☁️ iCloud disabled for this launch, using local storage")
            return false
        }

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

    /// Migrate local funds to iCloud if iCloud became available.
    ///
    /// Performs synchronous file I/O (copyItem per fund) on the actor's executor, which
    /// blocks the actor for the duration. Left synchronous deliberately: it runs once,
    /// off the main thread (callers `await` it from a detached load path), only copies
    /// files that don't already exist in iCloud, and a one-time migration that takes a
    /// few hundred ms for large portfolios is acceptable versus the added complexity /
    /// changed semantics of chunking it across suspension points. Revisit only if a
    /// portfolio large enough to noticeably stall the actor appears.
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

    /// Replace the funds directory with the bundled test-data set.
    ///
    /// `nonisolated` and synchronous so it can run from `EscapeMintApp.init()` —
    /// which is not async — before any view loads. It only touches the
    /// `nonisolated` `fundsDirectory` and the read-only app bundle, so it does
    /// not need the actor's mutable state. Mirrors the test/demo data the
    /// `-loadTestData` launch argument expects.
    nonisolated func loadTestDataSynchronously() {
        let fm = FileManager.default
        let dir = fundsDirectory
        // Delete all existing funds.
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
        // Copy test data from the bundle.
        let testFundIds = [
            "coinbasetest-btc", "coinbasetest-cash",
            "robinhoodtest-tqqq", "robinhoodtest-spxl", "robinhoodtest-cash"
        ]
        for fundId in testFundIds {
            if let jsonURL = Bundle.main.url(forResource: fundId, withExtension: "json"),
               let tsvURL = Bundle.main.url(forResource: fundId, withExtension: "tsv") {
                try? fm.copyItem(at: jsonURL, to: dir.appendingPathComponent("\(fundId).json"))
                try? fm.copyItem(at: tsvURL, to: dir.appendingPathComponent("\(fundId).tsv"))
            }
        }
    }

    /// Read entries for a single fund by its id — nonisolated for true parallel I/O.
    nonisolated func readFundEntries(id: String) -> [FundEntry] {
        let tsvURL = Self.currentFundsDirectory.appendingPathComponent("\(id).tsv")
        guard let content = try? String(contentsOf: tsvURL, encoding: .utf8) else { return [] }
        return parseTSV(content)
    }

    /// Shared JSON config reader — used by both readAllFundConfigs and readFund
    private nonisolated func readFundConfig(jsonURL: URL) -> FundData? {
        guard var config = decodeJSONFile(jsonURL, as: FundConfig.self),
              let platform = config.platform, let ticker = config.ticker else { return nil }
        if config.fund_id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            config.fund_id = jsonURL.deletingPathExtension().lastPathComponent
        }
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

    /// Re-apply complete file protection to a fund file on iOS. Atomic writes create a
    /// new file via rename (and older iOS in-place overwrites can strip the attribute),
    /// so every write path re-applies it. No-op on macOS. Failures are intentionally
    /// ignored — protection is best-effort hardening, not a correctness requirement.
    private func applyCompleteProtection(to url: URL) {
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    func writeFund(_ fund: FundData) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fund.id).tsv")
        let configURL = fundsDirectory.appendingPathComponent("\(fund.id).json")

        // Write config with metadata
        var configWithMeta = fund.config
        configWithMeta.fund_id = fund.id
        configWithMeta.platform = fund.platform
        configWithMeta.ticker = fund.ticker
        let configData = try JSONEncoder.pretty.encode(configWithMeta)
        try configData.write(to: configURL)

        // Write entries
        let tsv = buildTSV(fund.entries)
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)

        applyCompleteProtection(to: configURL)
        applyCompleteProtection(to: tsvURL)
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

        // Atomicity trade-off: this is an in-place FileHandle append, not an atomic
        // rewrite. A crash mid-write could leave a truncated final line. We accept that
        // because a full atomic rewrite (read all + serialize + atomic replace) per
        // single-entry append is too costly for hot paths. The risk is bounded: a
        // truncated final row loses its trailing columns (the leading `date` column is
        // written first), and `parseEntryRow` defensively drops any row whose `date`
        // column is empty — so a partial line cannot poison APY/gain math as a zeroed
        // entry. Worst case is the silent loss of the single in-flight append.
        // Re-apply complete file protection like the sibling atomic write paths
        // (writeFund/replaceEntries). An in-place append does not create a new file,
        // but re-applying keeps the attribute consistent across all TSV write paths.
        applyCompleteProtection(to: tsvURL)
    }

    func replaceEntries(fundId: String, entries: [FundEntry]) throws {
        let tsvURL = fundsDirectory.appendingPathComponent("\(fundId).tsv")
        guard fileManager.fileExists(atPath: tsvURL.path) else { return }
        let tsv = buildTSV(entries)
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
        // Re-apply file protection after atomic write (atomic creates a new file via rename)
        applyCompleteProtection(to: tsvURL)
    }

    /// Updates a fund's config JSON. Returns `false` (without throwing) when the fund's
    /// file doesn't exist yet — addFund/recompute can race with writeFund, so callers
    /// must NOT assume a successful return means bytes hit the disk. Use the return value
    /// to gate any in-memory state that "shadows" the on-disk config.
    @discardableResult
    func updateConfig(fundId: String, config: FundConfig) throws -> Bool {
        let configURL = fundsDirectory.appendingPathComponent("\(fundId).json")
        guard fileManager.fileExists(atPath: configURL.path) else { return false }

        let existing = try Data(contentsOf: configURL)
        let existingConfig = try JSONDecoder().decode(FundConfig.self, from: existing)

        var updated = config
        // Preserve identity fields from disk. The caller-provided config might be missing or
        // stale on these (e.g. a settings-view edit that only updates DCA params), and a
        // mismatched fund_id would break FundData.id and every downstream lookup.
        updated.platform = existingConfig.platform
        updated.ticker = existingConfig.ticker
        updated.fund_id = existingConfig.fund_id
        let data = try JSONEncoder.pretty.encode(updated)
        try data.write(to: configURL, options: .atomic)
        // Re-apply file protection after atomic write — non-atomic in-place overwrites
        // on older iOS can strip the protection attribute.
        applyCompleteProtection(to: configURL)
        return true
    }

    /// Read-modify-write of the `history_cache` slot on a fund's config JSON. The write is
    /// still a full atomic rewrite of the file, but the encoded bytes are based on the latest
    /// *on-disk* config (re-read here) rather than an in-memory snapshot — so concurrent edits
    /// to other fields (chart_bounds, etc.) that landed on disk between recompute and this
    /// write are preserved. Returns `false` if the fund file doesn't exist yet (addFund /
    /// recompute can race writeFund).
    @discardableResult
    func updateHistoryCache(fundId: String, cache: FundHistoryCache?) throws -> Bool {
        let configURL = fundsDirectory.appendingPathComponent("\(fundId).json")
        guard fileManager.fileExists(atPath: configURL.path) else { return false }

        let existing = try Data(contentsOf: configURL)
        var existingConfig = try JSONDecoder().decode(FundConfig.self, from: existing)
        existingConfig.history_cache = cache
        let data = try JSONEncoder.pretty.encode(existingConfig)
        try data.write(to: configURL, options: .atomic)
        applyCompleteProtection(to: configURL)
        return true
    }

    func deleteFund(id: String) throws {
        try deleteFundFiles(id: id, in: fundsDirectory)
        if isICloud, let localFunds = localFundsDirectory(), localFunds != fundsDirectory {
            try deleteFundFiles(id: id, in: localFunds)
        }
    }

    func deletePlatform(named platform: String) throws -> Int {
        let cleanPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanPlatform.isEmpty else { return 0 }

        var deletedIds = Set<String>()
        let dirs = deletionDirectories()
        for dir in dirs {
            let ids = fundIds(onPlatform: cleanPlatform, in: dir)
            for id in ids {
                try deleteFundFiles(id: id, in: dir)
                deletedIds.insert(id)
            }
        }
        return deletedIds.count
    }

    func deleteAllFunds() throws {
        try deleteAllFundFiles(in: fundsDirectory)

        // When using iCloud, also clear the local Documents/funds/ directory
        // to prevent migrateToICloudIfNeeded() from restoring deleted data on next launch
        if isICloud, let localFunds = localFundsDirectory(), localFunds != fundsDirectory {
            try deleteAllFundFiles(in: localFunds)
        }
    }

    private func deleteFundFiles(id: String, in directory: URL) throws {
        let tsvURL = directory.appendingPathComponent("\(id).tsv")
        let configURL = directory.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: tsvURL.path) {
            try fileManager.removeItem(at: tsvURL)
        }
        if fileManager.fileExists(atPath: configURL.path) {
            try fileManager.removeItem(at: configURL)
        }
    }

    private func deleteAllFundFiles(in directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            try fileManager.removeItem(at: file)
        }
    }

    private func deletionDirectories() -> [URL] {
        var dirs = [fundsDirectory]
        if isICloud, let localFunds = localFundsDirectory(), localFunds != fundsDirectory {
            dirs.append(localFunds)
        }
        return dirs
    }

    private func localFundsDirectory() -> URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("funds")
    }

    private func fundIds(onPlatform platform: String, in directory: URL) -> Set<String> {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return Set(files.compactMap { file in
            guard file.pathExtension == "json",
                  let config = decodeJSONFile(file, as: FundConfig.self),
                  config.platform?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == platform else {
                return nil
            }
            return file.deletingPathExtension().lastPathComponent
        })
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

    func backupJSONFundCount(_ jsonURL: URL) throws -> Int {
        let data = try Data(contentsOf: jsonURL)
        return try Self.decodeBackup(data).funds.count
    }

    /// Decode a backup file into the type-safe `BackupDocument`, mapping any decoding
    /// failure to the legacy `FundStore` error so the UI surfaces a clear message.
    private static func decodeBackup(_ data: Data) throws -> BackupDocument {
        do {
            return try JSONDecoder().decode(BackupDocument.self, from: data)
        } catch {
            throw NSError(domain: "FundStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid backup format: missing 'funds' array"])
        }
    }

    func importFromBackupJSON(_ jsonURL: URL) throws -> Int {
        // Ensure funds directory exists
        try? fileManager.createDirectory(at: fundsDirectory, withIntermediateDirectories: true)

        let data = try Data(contentsOf: jsonURL)
        let backup = try Self.decodeBackup(data)

        let safeFundIdPattern = /^[a-zA-Z0-9._-]+$/
        var imported = 0
        for fund in backup.funds {
            let id = fund.id
            let platform = fund.platform
            let ticker = fund.ticker

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
                // Stamp the on-disk identity metadata (the `__`-prefixed keys) from the
                // top-level fund fields, which are authoritative for filenames/lookups.
                var configWithMeta = fund.config
                configWithMeta.fund_id = id
                configWithMeta.platform = platform
                configWithMeta.ticker = ticker

                let configData = try JSONEncoder.pretty.encode(configWithMeta)
                try configData.write(to: configURL, options: .atomic)
                applyCompleteProtection(to: configURL)

                let tsv = buildTSV(fund.entries)
                try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
                applyCompleteProtection(to: tsvURL)
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

        let backupFunds: [BackupFund] = funds.map { fund in
            // Stamp the `__`-prefixed identity keys onto the config so the exported
            // file mirrors the on-disk per-fund JSON the web app reads.
            var configWithMeta = fund.config
            configWithMeta.fund_id = fund.id
            configWithMeta.platform = fund.platform
            configWithMeta.ticker = fund.ticker
            return BackupFund(
                id: fund.id,
                platform: fund.platform,
                ticker: fund.ticker,
                config: configWithMeta,
                entries: fund.entries
            )
        }

        let backup = BackupDocument(
            funds: backupFunds,
            backupDate: ISO8601DateFormatter().string(from: Date())
        )

        let data = try JSONEncoder.pretty.encode(backup)

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

    /// Export a backup JSON and move it into the user's Documents directory, returning
    /// the destination URL. Encapsulates the documentDirectory resolution + move that
    /// the Settings view used to perform with direct FileManager calls.
    func exportToDocuments() throws -> URL {
        let backupURL = try exportToBackupJSON()
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "FundStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access Documents directory"])
        }
        let dest = docs.appendingPathComponent(backupURL.lastPathComponent)
        try? fileManager.removeItem(at: dest)
        try fileManager.moveItem(at: backupURL, to: dest)
        return dest
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

    struct DataStats: Sendable {
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

private let tsvLogger = Logger(subsystem: "net.shadowpuppet.EscapeMint", category: "TSVParsing")

private let entryHeaders = ["date", "value", "cash", "action", "amount", "shares", "price", "dividend", "expense", "cash_interest", "fund_size", "margin_available", "margin_borrowed", "margin_expense", "notes", "contracts", "entry_price", "liquidation_price", "unrealized_pnl", "margin_locked", "fee", "margin"]

func parseTSV(_ content: String) -> [FundEntry] {
    let lines = content.replacingOccurrences(of: "\r\n", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count > 1 else { return [] }

    let headers = lines[0].split(separator: "\t").map(String.init)
    // Malformed rows (missing/empty date) return nil and are dropped here rather than
    // flowing into APY/gain math as a zeroed FundEntry(date: "", value: 0).
    return lines.dropFirst().enumerated().compactMap { index, line in
        parseEntryRow(String(line), headers: headers, rowIndex: index + 1)
    }
}

/// Parse a TSV row, returning `nil` (and logging a warning with the 1-based data-row
/// index) when the `date` column is empty or missing so `parseTSV`'s `compactMap`
/// drops it. `parseEntry` itself stays non-optional for callers that parse a single
/// known-good row.
func parseEntryRow(_ line: String, headers: [String], rowIndex: Int) -> FundEntry? {
    let entry = parseEntry(line, headers: headers)
    guard !entry.date.isEmpty else {
        tsvLogger.warning("dropping malformed TSV row \(rowIndex): missing/empty date column")
        return nil
    }
    return entry
}

/// Rounds to `decimals` places to avoid IEEE 754 artifacts (e.g. 45.55000000000001).
private func roundTo(_ val: Double, decimals: Int) -> Double {
    let factor = pow(10.0, Double(decimals))
    return (val * factor).rounded() / factor
}

/// Round a currency value to 2 decimal places.
private func roundCurrency(_ val: Double) -> Double { roundTo(val, decimals: 2) }
private func roundCurrency(_ val: Double?) -> Double? { val.map { roundCurrency($0) } }
/// Shares/contracts and prices keep up to 8 decimals for fractional/low-price crypto (e.g. DOGE $0.09424).
private func roundQuantity(_ val: Double?) -> Double? { val.map { roundTo($0, decimals: 8) } }
private func roundPrice(_ val: Double?) -> Double? { roundQuantity(val) }

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
    return formatTrimmedDecimal(roundTo(v, decimals: 8))
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
