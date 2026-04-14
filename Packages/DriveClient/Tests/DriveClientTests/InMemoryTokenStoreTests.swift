import XCTest
@testable import DriveClient

final class InMemoryTokenStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.loadRefreshToken())
        try store.save(refreshToken: "abc")
        XCTAssertEqual(try store.loadRefreshToken(), "abc")
    }

    func testOverwrite() throws {
        let store = InMemoryTokenStore(initial: "first")
        try store.save(refreshToken: "second")
        XCTAssertEqual(try store.loadRefreshToken(), "second")
    }

    func testClear() throws {
        let store = InMemoryTokenStore(initial: "something")
        try store.clear()
        XCTAssertNil(try store.loadRefreshToken())
    }
}
