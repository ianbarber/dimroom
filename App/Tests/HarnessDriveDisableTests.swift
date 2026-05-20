@testable import Dimroom
import XCTest

/// Layer A coverage for #278 — the `DIMROOM_HARNESS_DISABLE_DRIVE` env
/// var that short-circuits `resolveDriveClient` to return `nil` before
/// `OAuthConfig.load()` is consulted. The point of the knob is to keep
/// dev machines with an OAuth-configured keychain from hanging on
/// `SecItemCopyMatching` during `attemptCatalogRestore`; the helper
/// here is the predicate that drives that decision, plus its
/// precedence against the existing `DIMROOM_HARNESS_DRIVE_STUB`
/// "fake client" knob.
final class HarnessDriveDisableTests: XCTestCase {
    // MARK: - shouldDisableDriveForHarness

    func testDisablePredicateFalseWhenUnset() {
        XCTAssertFalse(AppDelegate.shouldDisableDriveForHarness(env: [:]))
    }

    func testDisablePredicateTrueWhenSetToOne() {
        XCTAssertTrue(AppDelegate.shouldDisableDriveForHarness(
            env: ["DIMROOM_HARNESS_DISABLE_DRIVE": "1"]
        ))
    }

    /// Pins "is set" semantics — an empty value still opts in, matching
    /// `shouldAutoConfirmRestorePrompt`. A future change to "is set and
    /// non-empty" would silently break flow scripts that prepend the
    /// var without a value.
    func testDisablePredicateTrueWhenSetToEmptyString() {
        XCTAssertTrue(AppDelegate.shouldDisableDriveForHarness(
            env: ["DIMROOM_HARNESS_DISABLE_DRIVE": ""]
        ))
    }

    // MARK: - harnessDriveStrategy

    func testStrategyDefaultsToOAuthConfig() {
        XCTAssertEqual(
            AppDelegate.harnessDriveStrategy(env: [:]),
            .useOAuthConfig
        )
    }

    func testStrategyReturnsStubClientWhenOnlyStubSet() {
        XCTAssertEqual(
            AppDelegate.harnessDriveStrategy(
                env: ["DIMROOM_HARNESS_DRIVE_STUB": "1"]
            ),
            .stubClient
        )
    }

    func testStrategyReturnsDisabledWhenOnlyDisableSet() {
        XCTAssertEqual(
            AppDelegate.harnessDriveStrategy(
                env: ["DIMROOM_HARNESS_DISABLE_DRIVE": "1"]
            ),
            .disabled
        )
    }

    /// Pins precedence: `DRIVE_STUB` wins over `DISABLE_DRIVE`. Flows
    /// that intentionally exercise the stubbed connect path must keep
    /// working even when a CI harness wrapper layers the "skip Drive"
    /// knob on top.
    func testStrategyDriveStubWinsOverDisable() {
        XCTAssertEqual(
            AppDelegate.harnessDriveStrategy(env: [
                "DIMROOM_HARNESS_DRIVE_STUB": "1",
                "DIMROOM_HARNESS_DISABLE_DRIVE": "1",
            ]),
            .stubClient
        )
    }
}
