@testable import Dimroom
import XCTest

/// Layer A coverage for the two `--harness`-only seams added by #371 so
/// a Layer C flow can reproduce the #293 "failed-then-succeeded OAuth
/// with interim imports" window:
///
///   * `failFirstOAuthCount(env:)` decides how many OAuth authorize
///     attempts the stub `DriveClient` should deny before succeeding.
///   * `shouldGateWithoutAutoConnect(env:)` arms the same-session restore
///     gate at launch without auto-firing the menu Connect flow, leaving
///     the harness to drive both attempts via `connect-drive`.
///
/// Both are pure functions over the environment dictionary, so they pin
/// the parsing without constructing an `AppDelegate` (which would drag in
/// `NSApplication`). The instance-flag wiring in `.offerConnectNoAuth`
/// is exercised end-to-end by
/// `bin/harness-restore-catalog-connect-in-session-with-imports-flow.sh`.
final class FailFirstOAuthSeamTests: XCTestCase {
    private let failKey = "DIMROOM_HARNESS_DRIVE_STUB_FAIL_FIRST_OAUTH"
    private let gateKey = "DIMROOM_HARNESS_GATE_WITHOUT_AUTOCONNECT"

    // MARK: - failFirstOAuthCount

    func testFailCountIsZeroWhenUnset() {
        XCTAssertEqual(AppDelegate.failFirstOAuthCount(env: [:]), 0)
    }

    func testFailCountParsesNumericValue() {
        XCTAssertEqual(
            AppDelegate.failFirstOAuthCount(env: [failKey: "1"]), 1
        )
        XCTAssertEqual(
            AppDelegate.failFirstOAuthCount(env: [failKey: "3"]), 3
        )
    }

    func testFailCountZeroValueDisablesFailures() {
        // An explicit "0" means never fail — the count flows straight to
        // `HarnessFailFirstBrowserLauncher(failures:)`, and 0 there is the
        // always-succeed case (matching the default stub launcher).
        XCTAssertEqual(
            AppDelegate.failFirstOAuthCount(env: [failKey: "0"]), 0
        )
    }

    /// Present-but-non-numeric (e.g. the bare `=1`-style opt-in that other
    /// knobs accept as any value) falls back to a usable single failure
    /// rather than silently disabling the seam.
    func testFailCountNonNumericFallsBackToOne() {
        XCTAssertEqual(
            AppDelegate.failFirstOAuthCount(env: [failKey: ""]), 1
        )
        XCTAssertEqual(
            AppDelegate.failFirstOAuthCount(env: [failKey: "yes"]), 1
        )
    }

    // MARK: - shouldGateWithoutAutoConnect

    func testGateWithoutAutoConnectFalseWhenUnset() {
        XCTAssertFalse(AppDelegate.shouldGateWithoutAutoConnect(env: [:]))
    }

    func testGateWithoutAutoConnectTrueWhenSet() {
        XCTAssertTrue(
            AppDelegate.shouldGateWithoutAutoConnect(env: [gateKey: "1"])
        )
    }

    /// Pins "is set" semantics — an empty value still opts in, matching
    /// `shouldDisableDriveForHarness`. A flow that prepends the var
    /// without a value must still suppress the auto-connect.
    func testGateWithoutAutoConnectTrueWhenSetToEmptyString() {
        XCTAssertTrue(
            AppDelegate.shouldGateWithoutAutoConnect(env: [gateKey: ""])
        )
    }
}
