import XCTest
@testable import UI

final class PointerEventGeometryTests: XCTestCase {
    func testCenterDefaultMapsToFrameMidX() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 20)
        let point = PointerEventGeometry.windowPoint(
            globalFrame: frame,
            contentHeight: 768,
            fraction: 0.5
        )
        XCTAssertEqual(point.x, 200, accuracy: 0.0001) // 100 + 0.5 * 200
    }

    func testFractionMapsAcrossWidth() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 20)
        let quarter = PointerEventGeometry.windowPoint(
            globalFrame: frame,
            contentHeight: 768,
            fraction: 0.25
        )
        XCTAssertEqual(quarter.x, 150, accuracy: 0.0001) // 100 + 0.25 * 200

        let leftEdge = PointerEventGeometry.windowPoint(
            globalFrame: frame,
            contentHeight: 768,
            fraction: 0.0
        )
        XCTAssertEqual(leftEdge.x, 100, accuracy: 0.0001)

        let rightEdge = PointerEventGeometry.windowPoint(
            globalFrame: frame,
            contentHeight: 768,
            fraction: 1.0
        )
        XCTAssertEqual(rightEdge.x, 300, accuracy: 0.0001)
    }

    func testFractionIsClampedToUnitInterval() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 10)
        let below = PointerEventGeometry.windowPoint(globalFrame: frame, contentHeight: 768, fraction: -1)
        XCTAssertEqual(below.x, 0, accuracy: 0.0001)
        let above = PointerEventGeometry.windowPoint(globalFrame: frame, contentHeight: 768, fraction: 2)
        XCTAssertEqual(above.x, 100, accuracy: 0.0001)
    }

    func testYAxisIsFlippedAgainstContentHeight() {
        // A frame near the TOP of a top-left SwiftUI space (small midY)
        // must map to a LARGE window Y (near the top in bottom-left
        // AppKit coordinates).
        let topFrame = CGRect(x: 0, y: 0, width: 100, height: 20) // midY = 10
        let topPoint = PointerEventGeometry.windowPoint(
            globalFrame: topFrame,
            contentHeight: 768,
            fraction: 0.5
        )
        XCTAssertEqual(topPoint.y, 758, accuracy: 0.0001) // 768 - 10

        // A frame near the BOTTOM (large midY) maps to a small window Y.
        let bottomFrame = CGRect(x: 0, y: 738, width: 100, height: 20) // midY = 748
        let bottomPoint = PointerEventGeometry.windowPoint(
            globalFrame: bottomFrame,
            contentHeight: 768,
            fraction: 0.5
        )
        XCTAssertEqual(bottomPoint.y, 20, accuracy: 0.0001) // 768 - 748
    }
}
