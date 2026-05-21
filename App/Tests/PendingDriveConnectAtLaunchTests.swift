@testable import Dimroom
import XCTest

/// Layer A coverage for the launch-time "Connect Google Drive?" alert
/// wiring introduced by #256. The flag itself lives as an instance
/// var on `AppDelegate`, but the set/consume semantics are pure
/// boolean state — we exercise them via `consumePendingConnectFlag`
/// and the env-var helpers so the test does not need to construct
/// an `AppDelegate` (which would drag in `NSApplication`).
final class PendingDriveConnectAtLaunchTests: XCTestCase {
    // MARK: - consumePendingConnectFlag

    func testConsumeReturnsCurrentValueAndClears() {
        var flag = true
        let consumed = AppDelegate.consumePendingConnectFlag(&flag)
        XCTAssertTrue(consumed, "consume should return the prior value")
        XCTAssertFalse(flag, "consume must clear so the next launch tick is a no-op")
    }

    func testConsumeIsIdempotent() {
        var flag = true
        _ = AppDelegate.consumePendingConnectFlag(&flag)
        let second = AppDelegate.consumePendingConnectFlag(&flag)
        XCTAssertFalse(second, "second consume must report false — flag is one-shot")
    }

    func testConsumeReturnsFalseWhenUnset() {
        var flag = false
        let consumed = AppDelegate.consumePendingConnectFlag(&flag)
        XCTAssertFalse(consumed)
        XCTAssertFalse(flag)
    }

    // MARK: - harness env-var auto-confirm

    func testConnectValueParsing() {
        // Mirrors the parsing branch in
        // `harnessConnectForRestoreValue()`. `setenv` shapes the
        // helper's view of the environment without affecting other
        // tests because we restore in `tearDown`.
        let key = "DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE"
        defer { unsetenv(key) }

        setenv(key, "connect", 1)
        XCTAssertTrue(AppDelegate.shouldAutoConfirmConnectForRestorePrompt())
        XCTAssertTrue(AppDelegate.harnessConnectForRestoreValue())

        setenv(key, "skip", 1)
        XCTAssertTrue(AppDelegate.shouldAutoConfirmConnectForRestorePrompt())
        XCTAssertFalse(AppDelegate.harnessConnectForRestoreValue())

        setenv(key, "1", 1)
        XCTAssertTrue(AppDelegate.harnessConnectForRestoreValue(), "`1` should map to connect")
    }

    func testEnvUnsetReportsNoAutoConfirm() {
        let key = "DIMROOM_HARNESS_AUTO_CONFIRM_CONNECT_FOR_RESTORE"
        unsetenv(key)
        XCTAssertFalse(AppDelegate.shouldAutoConfirmConnectForRestorePrompt())
    }
}
