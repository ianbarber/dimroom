@testable import Dimroom
import XCTest

/// Layer A coverage for `AppDelegate.chooseTokenStoreKind`. The
/// underlying `resolveDriveClient` path needs to skip the Keychain
/// when launched with `--harness` (#260), otherwise SPM's debug-build
/// resign pops a Keychain password prompt on every rebuild. The pure
/// helper lets us pin every branch without instantiating
/// `DriveClient` (which would touch the real Keychain in the
/// production branch).
final class DriveClientResolutionTests: XCTestCase {
    func testProductionLaunchUsesKeychain() {
        let kind = AppDelegate.chooseTokenStoreKind(
            args: ["/Applications/Dimroom.app/Contents/MacOS/Dimroom"],
            env: [:]
        )
        XCTAssertEqual(kind, .keychain)
    }

    func testHarnessLaunchSkipsKeychain() {
        let kind = AppDelegate.chooseTokenStoreKind(
            args: ["dimroom", "--harness"],
            env: [:]
        )
        XCTAssertEqual(kind, .inMemory)
    }

    func testHarnessWithRealOAuthConfigStillSkipsKeychain() {
        // The bug surface: a real `DIMROOM_GOOGLE_CLIENT_ID` is set
        // (so `OAuthConfig.load()` would succeed), but `--harness` is
        // present. Production credentials must not flow through the
        // Keychain in a harness run.
        let kind = AppDelegate.chooseTokenStoreKind(
            args: ["dimroom", "--harness"],
            env: ["DIMROOM_GOOGLE_CLIENT_ID": "test-client-id"]
        )
        XCTAssertEqual(kind, .inMemory)
    }

    func testHarnessWithDriveStubUsesStubInMemory() {
        let kind = AppDelegate.chooseTokenStoreKind(
            args: ["dimroom", "--harness"],
            env: ["DIMROOM_HARNESS_DRIVE_STUB": "1"]
        )
        XCTAssertEqual(kind, .stubInMemory)
    }

    func testStubEnvWithoutHarnessIsKeychain() {
        // Without `--harness` the harness env vars are irrelevant —
        // production launches always go through the Keychain.
        let kind = AppDelegate.chooseTokenStoreKind(
            args: ["dimroom"],
            env: ["DIMROOM_HARNESS_DRIVE_STUB": "1"]
        )
        XCTAssertEqual(kind, .keychain)
    }

    func testTokenStoreKindRawValuesAreWireStable() {
        // Layer C flows assert on these strings (the JSON payload of
        // `drive-auth-state`). Pin them here so a rename surfaces as a
        // unit-test failure rather than a flaky harness run.
        XCTAssertEqual(AppDelegate.TokenStoreKind.keychain.rawValue, "keychain")
        XCTAssertEqual(AppDelegate.TokenStoreKind.inMemory.rawValue, "in-memory")
        XCTAssertEqual(AppDelegate.TokenStoreKind.stubInMemory.rawValue, "stub-in-memory")
    }
}
