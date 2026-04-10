import XCTest
@testable import Harness

final class HarnessTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(Harness.self)
    }
}
