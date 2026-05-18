@testable import Dimroom
import XCTest

/// Layer A coverage for the pure launch-time decision tree introduced
/// by #234. The actual `attemptCatalogRestore` body is bound up with
/// `FileManager`, `DriveClient`, and `NSAlert` side effects; the
/// decision function lets us pin every branch without launching the
/// app or scheduling the runBlocking bridge.
final class CatalogRestoreDecisionTests: XCTestCase {
    func testLocalCatalogPresentSkipsRestore() {
        let decision = AppDelegate.launchRestoreDecision(
            localCatalogPresent: true,
            hasStubUploader: false,
            hasDriveClient: true,
            isAuthenticated: true
        )
        XCTAssertEqual(decision, .skipLocalPresent)
    }

    func testStubUploaderShortCircuitsAuthCheck() {
        // The harness stub uploader simulates "an existing catalog
        // lives on Drive" without touching Google. We want the launch
        // path to take it even when no real DriveClient is wired up.
        let decision = AppDelegate.launchRestoreDecision(
            localCatalogPresent: false,
            hasStubUploader: true,
            hasDriveClient: false,
            isAuthenticated: false
        )
        XCTAssertEqual(decision, .attemptRestoreWithStub)
    }

    func testAuthenticatedDriveClientAttemptsRestore() {
        let decision = AppDelegate.launchRestoreDecision(
            localCatalogPresent: false,
            hasStubUploader: false,
            hasDriveClient: true,
            isAuthenticated: true
        )
        XCTAssertEqual(decision, .attemptRestoreWithDrive)
    }

    func testNoAuthOffersConnect() {
        let decision = AppDelegate.launchRestoreDecision(
            localCatalogPresent: false,
            hasStubUploader: false,
            hasDriveClient: true,
            isAuthenticated: false
        )
        XCTAssertEqual(decision, .offerConnectNoAuth)
    }

    func testNoDriveClientOffersConnect() {
        // A machine that never had Drive configured falls through to
        // the connect-or-skip alert, not a silent no-op. Before #234
        // this returned silently and the user got an empty catalog
        // with no explanation.
        let decision = AppDelegate.launchRestoreDecision(
            localCatalogPresent: false,
            hasStubUploader: false,
            hasDriveClient: false,
            isAuthenticated: false
        )
        XCTAssertEqual(decision, .offerConnectNoAuth)
    }
}
