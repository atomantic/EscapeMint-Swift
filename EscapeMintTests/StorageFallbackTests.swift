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
