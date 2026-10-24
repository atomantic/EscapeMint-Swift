import XCTest
@testable import EscapeMint

/// Coverage for `FundStore.resolveDirectoryState` — the iCloud/local directory selection
/// that previously had zero test coverage (issue #47). A regression here silently strands
/// user data (e.g. resolving to the temp directory or an inaccessible iCloud container),
/// so each branch is asserted explicitly via the injectable seam: a temp `FileManager`
/// plus a fake `ubiquityURLProvider`.
final class StorageFallbackTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscapeMintFallbackTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Compare two file URLs ignoring a trailing slash (an existing-directory URL gains a
    /// trailing `/` once the directory is created, the resolver's appendingPathComponent
    /// result does not).
    private func assertSamePath(_ a: URL, _ b: URL, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        let pa = a.path.hasSuffix("/") ? String(a.path.dropLast()) : a.path
        let pb = b.path.hasSuffix("/") ? String(b.path.dropLast()) : b.path
        XCTAssertEqual(pa, pb, message, file: file, line: line)
    }

    // MARK: - iCloud available

    /// iCloud URL non-nil AND the container directory is creatable + listable →
    /// resolves to the iCloud `Documents/funds` directory with `isICloud == true`.
    func testICloudAvailableUsesICloudDirectory() {
        let iCloudRoot = tempDir.appendingPathComponent("iCloudContainer")
        try? FileManager.default.createDirectory(at: iCloudRoot, withIntermediateDirectories: true)

        let state = FundStore.resolveDirectoryState(
            fm: FileManager.default,
            skipICloud: false,
            ubiquityURLProvider: { iCloudRoot }
        )

        XCTAssertTrue(state.isICloud)
        assertSamePath(state.fundsDirectory, iCloudRoot.appendingPathComponent("Documents/funds"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.fundsDirectory.path),
                      "iCloud funds directory should have been created")
    }

    // MARK: - iCloud container present but inaccessible

    /// iCloud URL non-nil but `contentsOfDirectory` fails (gotcha #4: non-nil ubiquity URL
    /// is NOT proof the container is usable) → falls back to LOCAL Documents, never temp,
    /// and `isICloud == false`. This is the branch that, if it regressed to temp, would
    /// silently strand user data.
    func testICloudInaccessibleFallsBackToLocalNotTemp() {
        let iCloudRoot = tempDir.appendingPathComponent("iCloudContainer")
        let inaccessibleFunds = iCloudRoot.appendingPathComponent("Documents/funds")
        let fm = InaccessibleICloudFileManager(failingPath: inaccessibleFunds.path,
                                               localDocuments: tempDir.appendingPathComponent("Documents"))

        let state = FundStore.resolveDirectoryState(
            fm: fm,
            skipICloud: false,
            ubiquityURLProvider: { iCloudRoot }
        )

        XCTAssertFalse(state.isICloud, "should not report iCloud when container is inaccessible")
        assertSamePath(state.fundsDirectory,
                       tempDir.appendingPathComponent("Documents/funds"),
                       "should fall back to local Documents/funds, NOT the bare temp directory")
        XCTAssertTrue(state.fundsDirectory.path.contains("/Documents/funds"),
                      "fallback must resolve under Documents, not a bare temp/funds path")
    }

    // MARK: - iCloud URL nil

    /// iCloud URL is nil (e.g. signed out / not yet provisioned) → falls back to local
    /// Documents, `isICloud == false`.
    func testICloudURLNilFallsBackToLocal() {
        let fm = LocalDocumentsFileManager(localDocuments: tempDir.appendingPathComponent("Documents"))

        let state = FundStore.resolveDirectoryState(
            fm: fm,
            skipICloud: false,
            ubiquityURLProvider: { nil }
        )

        XCTAssertFalse(state.isICloud)
        assertSamePath(state.fundsDirectory, tempDir.appendingPathComponent("Documents/funds"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.fundsDirectory.path))
    }

    // MARK: - iCloud skipped

    /// `skipICloud == true` (e.g. simulator / -skipICloud launch arg) → never consults the
    /// ubiquity provider, resolves to local Documents.
    func testSkipICloudUsesLocalAndIgnoresProvider() {
        let fm = LocalDocumentsFileManager(localDocuments: tempDir.appendingPathComponent("Documents"))
        var providerCalled = false

        let state = FundStore.resolveDirectoryState(
            fm: fm,
            skipICloud: true,
            ubiquityURLProvider: { providerCalled = true; return self.tempDir }
        )

        XCTAssertFalse(providerCalled, "skipICloud must short-circuit before touching iCloud")
        XCTAssertFalse(state.isICloud)
        assertSamePath(state.fundsDirectory, tempDir.appendingPathComponent("Documents/funds"))
    }
}

// MARK: - Test doubles

/// FileManager that redirects `.documentDirectory` lookups to a test-controlled location
/// so the local-fallback branch resolves under the temp dir instead of the real Documents.
private class LocalDocumentsFileManager: FileManager {
    let localDocuments: URL
    init(localDocuments: URL) {
        self.localDocuments = localDocuments
        super.init()
        try? FileManager.default.createDirectory(at: localDocuments, withIntermediateDirectories: true)
    }

    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        if directory == .documentDirectory {
            return [localDocuments]
        }
        return super.urls(for: directory, in: domainMask)
    }
}

/// FileManager that simulates an iCloud container whose directory creation "succeeds" but
/// whose `contentsOfDirectory` throws — the gotcha-#4 accessibility failure. Local
/// Documents lookups are redirected to a test location.
private final class InaccessibleICloudFileManager: LocalDocumentsFileManager {
    let failingPath: String
    init(failingPath: String, localDocuments: URL) {
        self.failingPath = failingPath
        super.init(localDocuments: localDocuments)
    }

    override func createDirectory(at url: URL,
                                  withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        // Pretend the iCloud directory create succeeds (matches the real gotcha-#4
        // scenario where create appears fine but the dir isn't actually usable).
        if url.path == failingPath { return }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }

    override func contentsOfDirectory(at url: URL,
                                      includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.path == failingPath {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                          userInfo: [NSLocalizedDescriptionKey: "simulated iCloud permission denied"])
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

// MARK: - Import and migration recovery

extension StorageFallbackTests {
    private func recoveryStore(failLocalInstall: Bool = false, failCloudRestore: Bool = false) throws
        -> (store: FundStore, cloud: URL, local: URL) {
        let cloud = tempDir.appendingPathComponent("Cloud/funds")
        let localDocuments = tempDir.appendingPathComponent("Local")
        let local = localDocuments.appendingPathComponent("funds")
        let fm = RecoveryFileManager(
            localDocuments: localDocuments,
            failedInstall: failLocalInstall ? local.path : nil,
            failedRestore: failCloudRestore ? cloud.path : nil
        )
        for directory in [cloud, local] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return (FundStore(fundsDirectory: cloud, isICloud: true, fileManager: fm), cloud, local)
    }

    private func recoveryFund(_ id: String, value: Double) -> FundData {
        FundData(platform: "broker", ticker: "asset", config: FundConfig(fund_id: id, fund_type: .stock),
                 entries: [FundEntry(date: "2025-01-01", value: value)])
    }

    private func recoveryBackup(_ funds: [FundData]) throws -> URL {
        let document = BackupDocument(funds: funds.map {
            BackupFund(id: $0.id, platform: $0.platform, ticker: $0.ticker, config: $0.config, entries: $0.entries)
        }, backupDate: "2025-01-01")
        let url = tempDir.appendingPathComponent("backup.json")
        try JSONEncoder().encode(document).write(to: url)
        return url
    }

    private func directoryBytes(_ directory: URL) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            bytes[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return bytes
    }

    func testLegacyFundNamesRemainLoadableAndExportable() async throws {
        let (store, cloud, _) = try recoveryStore()
        let id = "Crédit broker-資産"
        var fund = recoveryFund(id, value: 123)
        fund.config.cash_fund = "Crédit broker-cash"
        // Seed bytes directly, as an older app would, without relying on the new writer.
        var diskConfig = fund.config
        diskConfig.platform = fund.platform
        diskConfig.ticker = fund.ticker
        try JSONEncoder().encode(diskConfig).write(to: cloud.appendingPathComponent("\(id).json"))
        try buildTSV(fund.entries).write(to: cloud.appendingPathComponent("\(id).tsv"), atomically: true, encoding: .utf8)

        let loaded = await store.readAllFunds()
        XCTAssertEqual(loaded.map(\.id), [id])
        XCTAssertEqual(loaded.first?.config.cash_fund, fund.config.cash_fund)
        XCTAssertEqual(store.readAllFundConfigs().map(\.id), [id])
        XCTAssertEqual(store.readFundEntries(id: id).first?.value, 123)
        let backup = try await store.exportToBackupJSON()
        defer { try? FileManager.default.removeItem(at: backup) }
        let exported = try JSONDecoder().decode(BackupDocument.self, from: Data(contentsOf: backup))
        XCTAssertEqual(exported.funds.map(\.id), [id])
        XCTAssertEqual(exported.funds.first?.config.cash_fund, fund.config.cash_fund)
    }

    func testMigrationPreservesExistingCloudTSVWhenRepairingMissingConfig() async throws {
        let (store, cloud, local) = try recoveryStore()
        let localStore = FundStore(fundsDirectory: local)
        try await localStore.writeFund(recoveryFund("broker-asset", value: 10))
        try await store.writeFund(recoveryFund("broker-asset", value: 900))
        let tsv = cloud.appendingPathComponent("broker-asset.tsv")
        let original = try Data(contentsOf: tsv)
        try FileManager.default.removeItem(at: cloud.appendingPathComponent("broker-asset.json"))

        try await store.migrateToICloudIfNeeded()

        XCTAssertEqual(try Data(contentsOf: tsv), original)
        let loaded = await store.readFundById("broker-asset")
        XCTAssertEqual(loaded?.entries.first?.value, 900)
    }

    func testMigrationPreservesExistingCloudConfigWhenRepairingMissingTSV() async throws {
        let (store, cloud, local) = try recoveryStore()
        let localStore = FundStore(fundsDirectory: local)
        try await localStore.writeFund(recoveryFund("broker-asset", value: 10))
        var newer = recoveryFund("broker-asset", value: 900)
        newer.config.target_apy = 0.37
        try await store.writeFund(newer)
        let config = cloud.appendingPathComponent("broker-asset.json")
        let original = try Data(contentsOf: config)
        try FileManager.default.removeItem(at: cloud.appendingPathComponent("broker-asset.tsv"))

        try await store.migrateToICloudIfNeeded()

        XCTAssertEqual(try Data(contentsOf: config), original)
        let loaded = await store.readFundById("broker-asset")
        XCTAssertEqual(loaded?.config.target_apy, 0.37)
        XCTAssertEqual(loaded?.entries.first?.value, 10)
    }

    func testReplaceAllUpdatesFallbackAndCannotResurrectRemovedFunds() async throws {
        let (store, cloud, local) = try recoveryStore()
        let localStore = FundStore(fundsDirectory: local)
        try await store.writeFund(recoveryFund("cloud-old", value: 10))
        try await localStore.writeFund(recoveryFund("local-old", value: 20))
        let backup = try recoveryBackup([recoveryFund("new-asset", value: 300)])

        let count = try await store.replaceAllFundsFromBackupJSON(backup)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try directoryBytes(cloud), try directoryBytes(local))
        // Simulator filesystems do not expose iOS data-protection attributes.
        #if os(iOS) && !targetEnvironment(simulator)
        for root in [cloud, local] {
            for ext in ["json", "tsv"] {
                let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("new-asset.\(ext)").path)
                XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
            }
        }
        #endif
        let fallbackFunds = await localStore.readAllFunds()
        XCTAssertEqual(fallbackFunds.map(\.id), ["new-asset"])
        try await store.migrateToICloudIfNeeded()
        let cloudFunds = await store.readAllFunds()
        XCTAssertEqual(cloudFunds.map(\.id), ["new-asset"])
        XCTAssertEqual(cloudFunds.first?.entries.first?.value, 300)
    }

    func testReplaceAllRestoresBothRootsWhenSecondInstallFails() async throws {
        let (store, cloud, local) = try recoveryStore(failLocalInstall: true)
        let localStore = FundStore(fundsDirectory: local)
        try await store.writeFund(recoveryFund("cloud-old", value: 10))
        try await localStore.writeFund(recoveryFund("local-old", value: 20))
        let originalCloud = try directoryBytes(cloud)
        let originalLocal = try directoryBytes(local)
        let backup = try recoveryBackup([recoveryFund("new-asset", value: 300)])

        do {
            _ = try await store.replaceAllFundsFromBackupJSON(backup)
            XCTFail("second-root installation must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("simulated install failure"))
        }
        XCTAssertEqual(try directoryBytes(cloud), originalCloud)
        XCTAssertEqual(try directoryBytes(local), originalLocal)
    }

    func testReplaceAllRetainsRecoveryCopyWhenOneRootCannotBeRestored() async throws {
        let (store, cloud, local) = try recoveryStore(failLocalInstall: true, failCloudRestore: true)
        let localStore = FundStore(fundsDirectory: local)
        try await store.writeFund(recoveryFund("cloud-old", value: 10))
        try await localStore.writeFund(recoveryFund("local-old", value: 20))
        let originalCloud = try directoryBytes(cloud)
        let originalLocal = try directoryBytes(local)
        let backup = try recoveryBackup([recoveryFund("new-asset", value: 300)])

        var failureMessage = ""
        do {
            _ = try await store.replaceAllFundsFromBackupJSON(backup)
            XCTFail("restoration must report failure")
        } catch { failureMessage = error.localizedDescription }
        let recovery = try FileManager.default.contentsOfDirectory(
            at: cloud.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".fund-rollback-") }
        XCTAssertEqual(recovery.count, 1)
        let recoveryURL = try XCTUnwrap(recovery.first)
        // Directory enumeration may resolve /var to /private/var; the error uses the original root.
        let recoveryPath = cloud.deletingLastPathComponent().appendingPathComponent(recoveryURL.lastPathComponent).path
        XCTAssertTrue(failureMessage.contains(recoveryPath), failureMessage)
        XCTAssertEqual(try directoryBytes(recoveryURL), originalCloud)
        XCTAssertEqual(try directoryBytes(local), originalLocal, "other roots must still be restored")
    }

    @MainActor
    func testPartialBackupMergeReloadsCommittedFundsAfterLaterPairFails() async throws {
        let (store, cloud, _) = try recoveryStore()
        try await store.writeFund(recoveryFund("first-asset", value: 10))
        try await store.writeFund(recoveryFund("second-asset", value: 20))
        let blockedConfig = cloud.appendingPathComponent("second-asset.json")
        try FileManager.default.removeItem(at: blockedConfig)
        try FileManager.default.createDirectory(at: blockedConfig, withIntermediateDirectories: true)
        let originalSecondTSV = try Data(contentsOf: cloud.appendingPathComponent("second-asset.tsv"))
        let backup = try recoveryBackup([
            recoveryFund("first-asset", value: 100), recoveryFund("second-asset", value: 200)
        ])
        let facade = FundDataStore(store: store)
        await facade.reload()
        let count = try await facade.importFromBackupJSON(backup, replacingExisting: false)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(facade.fund(byId: "first-asset")?.entries.first?.value, 100)
        let persisted = await store.readFundById("first-asset")
        XCTAssertEqual(persisted?.entries.first?.value, 100)
        XCTAssertEqual(try Data(contentsOf: cloud.appendingPathComponent("second-asset.tsv")), originalSecondTSV)
    }
}

private final class RecoveryFileManager: LocalDocumentsFileManager {
    let failedInstall: String?
    let failedRestore: String?

    init(localDocuments: URL, failedInstall: String?, failedRestore: String?) {
        self.failedInstall = failedInstall
        self.failedRestore = failedRestore
        super.init(localDocuments: localDocuments)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.path == failedInstall, srcURL.lastPathComponent.hasPrefix(".fund-import-") {
            throw NSError(domain: "RecoveryTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "simulated install failure"])
        }
        if dstURL.path == failedRestore, srcURL.lastPathComponent.hasPrefix(".fund-rollback-") {
            throw NSError(domain: "RecoveryTest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "simulated restore failure"])
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
