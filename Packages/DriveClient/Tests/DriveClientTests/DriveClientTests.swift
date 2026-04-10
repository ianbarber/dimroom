import XCTest
@testable import DriveClient

final class DriveClientTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(DriveClient.self)
    }
}
