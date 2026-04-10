import XCTest
@testable import SyncEngine

final class SyncEngineTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(SyncEngine.self)
    }
}
