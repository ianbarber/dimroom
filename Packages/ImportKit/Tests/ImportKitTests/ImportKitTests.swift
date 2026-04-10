import XCTest
@testable import ImportKit

final class ImportKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(ImportKit.self)
    }
}
