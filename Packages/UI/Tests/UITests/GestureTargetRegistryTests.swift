import XCTest
@testable import UI

@MainActor
final class GestureTargetRegistryTests: XCTestCase {
    func testRecordThenLookup() {
        let registry = GestureTargetRegistry()
        let frame = CGRect(x: 10, y: 20, width: 100, height: 30)
        registry.record("vignetteAmount", frame: frame)
        XCTAssertEqual(registry.frame(for: "vignetteAmount"), frame)
    }

    func testMissingKeyReturnsNil() {
        let registry = GestureTargetRegistry()
        XCTAssertNil(registry.frame(for: "exposure"))
    }

    func testRecordOverwritesPreviousFrame() {
        let registry = GestureTargetRegistry()
        registry.record("contrast", frame: CGRect(x: 0, y: 0, width: 50, height: 10))
        let updated = CGRect(x: 5, y: 200, width: 120, height: 14)
        registry.record("contrast", frame: updated)
        XCTAssertEqual(registry.frame(for: "contrast"), updated)
    }

    func testRemoveClearsKey() {
        let registry = GestureTargetRegistry()
        registry.record("tint", frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        registry.remove("tint")
        XCTAssertNil(registry.frame(for: "tint"))
    }

    func testKeysAreIndependent() {
        let registry = GestureTargetRegistry()
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 100, y: 100, width: 20, height: 20)
        registry.record("a", frame: a)
        registry.record("b", frame: b)
        XCTAssertEqual(registry.frame(for: "a"), a)
        XCTAssertEqual(registry.frame(for: "b"), b)
    }
}
