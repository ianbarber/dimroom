import XCTest
@testable import DriveClient

final class KeychainTokenStoreSmokeTests: XCTestCase {
    func testRoundTripAgainstRealKeychain() throws {
        guard ProcessInfo.processInfo.environment["DIMROOM_RUN_KEYCHAIN_TESTS"] == "1" else {
            throw XCTSkip("Set DIMROOM_RUN_KEYCHAIN_TESTS=1 to run real Keychain smoke tests")
        }

        let uuid = UUID().uuidString
        let store = KeychainTokenStore(
            service: "com.dimroom.DriveClient.smoketest.\(uuid)",
            account: "refresh_token.\(uuid)"
        )
        defer { try? store.clear() }

        XCTAssertNil(try store.loadRefreshToken(), "fresh service should have no item")

        try store.save(refreshToken: "token-a")
        XCTAssertEqual(try store.loadRefreshToken(), "token-a")

        try store.save(refreshToken: "token-b")
        XCTAssertEqual(try store.loadRefreshToken(), "token-b")

        try store.clear()
        XCTAssertNil(try store.loadRefreshToken(), "clear should remove the item")

        XCTAssertNoThrow(try store.clear(), "clear should be idempotent")
    }
}
