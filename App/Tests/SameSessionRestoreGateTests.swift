@testable import Dimroom
import UI
import XCTest

/// Layer A coverage for the pure `$status` transition predicate
/// driving the same-session restore (#283). Constructing an
/// `AppDelegate` here would drag `NSApplication` into the test bundle;
/// `shouldTriggerSameSessionRestore` is `nonisolated static` exactly
/// so we can exercise the five branches without that machinery.
final class SameSessionRestoreGateTests: XCTestCase {
    func testGateOpenAndConnectingToConnectedFires() {
        let triggered = AppDelegate.shouldTriggerSameSessionRestore(
            previous: .connecting,
            next: .connected(email: nil),
            gate: true
        )
        XCTAssertTrue(triggered)
    }

    func testGateOpenAndDisconnectedToConnectedFires() {
        // Hydrate completing after the launch path can flip the
        // status straight from `.disconnected` to `.connected` — the
        // sink must still trigger restore in that ordering.
        let triggered = AppDelegate.shouldTriggerSameSessionRestore(
            previous: .disconnected,
            next: .connected(email: "user@example.com"),
            gate: true
        )
        XCTAssertTrue(triggered)
    }

    func testGateOpenButConnectingToDisconnectedDoesNotFire() {
        // OAuth aborted by the user / refresh failure path — the gate
        // must stay closed until a real `.connected` arrival.
        let triggered = AppDelegate.shouldTriggerSameSessionRestore(
            previous: .connecting,
            next: .disconnected,
            gate: true
        )
        XCTAssertFalse(triggered)
    }

    func testConnectedToConnectedEmailRefreshDoesNotFire() {
        // `refreshEmail()` republishes `.connected(...)` with the
        // looked-up address. We do not want that secondary publish to
        // kick off another restore attempt.
        let triggered = AppDelegate.shouldTriggerSameSessionRestore(
            previous: .connected(email: nil),
            next: .connected(email: "user@example.com"),
            gate: true
        )
        XCTAssertFalse(triggered)
    }

    func testGateClosedSuppressesAllTransitions() {
        // Subsequent launches with a present local catalog never hit
        // `.offerConnectNoAuth`, so the gate stays closed. A reconnect
        // performed via the menu must not retrigger restore.
        let arrival = AppDelegate.shouldTriggerSameSessionRestore(
            previous: .connecting,
            next: .connected(email: nil),
            gate: false
        )
        XCTAssertFalse(arrival)

        let hydrate = AppDelegate.shouldTriggerSameSessionRestore(
            previous: .disconnected,
            next: .connected(email: "user@example.com"),
            gate: false
        )
        XCTAssertFalse(hydrate)
    }

    // MARK: - Launch-time stub uploader gate (#283)

    func testStubUploaderAtLaunchGateOff() {
        let key = "DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH"
        unsetenv(key)
        XCTAssertFalse(AppDelegate.shouldUseStubUploaderAtLaunch())
    }

    func testStubUploaderAtLaunchGateOn() {
        let key = "DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH"
        defer { unsetenv(key) }
        setenv(key, "1", 1)
        XCTAssertTrue(AppDelegate.shouldUseStubUploaderAtLaunch())
    }

    func testStubUploaderAtLaunchGateEmptyValueStillCounts() {
        // Mirrors `shouldDisableDriveForHarness`'s "is set" semantics
        // — presence in the env is enough, value is ignored.
        let key = "DIMROOM_HARNESS_STUB_REMOTE_CATALOG_AT_LAUNCH"
        defer { unsetenv(key) }
        setenv(key, "", 1)
        XCTAssertTrue(AppDelegate.shouldUseStubUploaderAtLaunch())
    }
}
