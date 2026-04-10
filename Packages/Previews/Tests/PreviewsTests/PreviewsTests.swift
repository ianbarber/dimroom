import XCTest
@testable import Previews

final class PreviewsTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(Previews.self)
    }
}
