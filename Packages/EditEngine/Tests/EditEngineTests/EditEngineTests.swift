import XCTest
@testable import EditEngine

final class EditEngineTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(EditEngine.self)
    }
}
