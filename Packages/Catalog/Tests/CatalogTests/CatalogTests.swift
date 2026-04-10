import XCTest
@testable import Catalog

final class CatalogTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertNotNil(Catalog.self)
    }
}
