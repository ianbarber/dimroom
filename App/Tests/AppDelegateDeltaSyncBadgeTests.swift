@testable import Dimroom
import SyncEngine
@testable import UI
import XCTest

/// Layer A coverage for `AppDelegate.applyNonModalDeltaSyncOutcome` —
/// the non-modal half of delta-sync dispatch that maps a
/// `DeltaSyncOutcome` to a mutation on `libraryViewModel`.
///
/// The headline guard is `.catalogChanged` clearing the remote-additions
/// badge: the pending catalog reload supersedes the "you might be missing
/// N photos" notice, so the dispatch must route to
/// `dismissRemoteAdditionsBadge()` rather than `recordRemoteOriginalsAdded`.
/// `dismissRemoteAdditionsBadge()` itself is covered by
/// `LibraryViewModelRemoteAdditionsTests`; what's covered here is the
/// routing — that a future refactor cannot silently swap arms.
///
/// `AppDelegate()` is constructed directly. This is safe because
/// `applicationDidFinishLaunching` is never invoked — `libraryViewModel`
/// is initialised eagerly with `LibraryViewModel.empty()` at field
/// declaration, so the instance is usable without any GUI/`NSApp`
/// lifecycle.
final class AppDelegateDeltaSyncBadgeTests: XCTestCase {

    @MainActor
    func testCatalogChangedClearsRemoteAdditionsBadge() {
        let appDelegate = AppDelegate()
        appDelegate.libraryViewModel.recordRemoteOriginalsAdded(count: 3)
        XCTAssertNotNil(appDelegate.libraryViewModel.remoteAdditionsBadge)

        appDelegate.applyNonModalDeltaSyncOutcome(
            .catalogChanged(driveFileId: "x", modifiedTime: nil, pageToken: "t")
        )

        XCTAssertNil(appDelegate.libraryViewModel.remoteAdditionsBadge)
    }

    @MainActor
    func testCatalogChangedIsIdempotentWhenNoBadgePresent() {
        let appDelegate = AppDelegate()
        XCTAssertNil(appDelegate.libraryViewModel.remoteAdditionsBadge)

        appDelegate.applyNonModalDeltaSyncOutcome(
            .catalogChanged(driveFileId: "x", modifiedTime: nil, pageToken: "t")
        )

        XCTAssertNil(appDelegate.libraryViewModel.remoteAdditionsBadge)
    }

    @MainActor
    func testOriginalsChangedOnlyPublishesBadge() {
        let appDelegate = AppDelegate()

        appDelegate.applyNonModalDeltaSyncOutcome(
            .originalsChangedOnly(addedCount: 2, pageToken: "t")
        )

        XCTAssertEqual(appDelegate.libraryViewModel.remoteAdditionsBadge?.addedCount, 2)
    }

    @MainActor
    func testBootstrappedLeavesBadgeUntouched() {
        let appDelegate = AppDelegate()
        appDelegate.libraryViewModel.recordRemoteOriginalsAdded(count: 4)

        appDelegate.applyNonModalDeltaSyncOutcome(.bootstrapped(pageToken: "t"))

        XCTAssertEqual(appDelegate.libraryViewModel.remoteAdditionsBadge?.addedCount, 4)
    }

    @MainActor
    func testNoChangesLeavesBadgeUntouched() {
        let appDelegate = AppDelegate()
        appDelegate.libraryViewModel.recordRemoteOriginalsAdded(count: 4)

        appDelegate.applyNonModalDeltaSyncOutcome(.noChanges(pageToken: "t"))

        XCTAssertEqual(appDelegate.libraryViewModel.remoteAdditionsBadge?.addedCount, 4)
    }

    @MainActor
    func testConflictLeavesBadgeUntouched() {
        let appDelegate = AppDelegate()
        appDelegate.libraryViewModel.recordRemoteOriginalsAdded(count: 4)

        appDelegate.applyNonModalDeltaSyncOutcome(
            .conflict(localPending: true, remoteFileId: "x", modifiedTime: nil, pageToken: "t")
        )

        XCTAssertEqual(appDelegate.libraryViewModel.remoteAdditionsBadge?.addedCount, 4)
    }
}
