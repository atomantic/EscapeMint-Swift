import XCTest
@testable import EscapeMint

final class ICloudSyncMonitorTests: XCTestCase {
    @MainActor
    func testRecentLocalWriteDefersReconciliationUntilWindowEnds() {
        let writeDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let notificationDate = writeDate.addingTimeInterval(2)

        let remaining = ICloudSyncMonitor.remainingWriteSuppressionInterval(
            lastWriteDate: writeDate,
            now: notificationDate,
            window: 5
        )

        XCTAssertEqual(remaining, 3, accuracy: 0.001)
    }

    @MainActor
    func testExpiredLocalWriteWindowAllowsImmediateReconciliation() {
        let writeDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let afterWindow = writeDate.addingTimeInterval(5)

        let remaining = ICloudSyncMonitor.remainingWriteSuppressionInterval(
            lastWriteDate: writeDate,
            now: afterWindow,
            window: 5
        )

        XCTAssertEqual(remaining, 0)
    }

    @MainActor
    func testLaterLocalWriteExtendsDeferredReconciliation() {
        let firstWrite = Date(timeIntervalSinceReferenceDate: 1_000)
        let firstWake = firstWrite.addingTimeInterval(5)
        let laterWrite = firstWrite.addingTimeInterval(4)

        let remaining = ICloudSyncMonitor.remainingWriteSuppressionInterval(
            lastWriteDate: laterWrite,
            now: firstWake,
            window: 5
        )

        XCTAssertEqual(remaining, 4, accuracy: 0.001)
    }
}
