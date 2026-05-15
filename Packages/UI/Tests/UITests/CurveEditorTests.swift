import CoreGraphics
import XCTest
@testable import UI

final class CurveEditorTests: XCTestCase {
    private let identity: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    // MARK: - insertPoint

    func testInsertPointOnFlatSegmentSnapsToLine() {
        let updated = CurveEditorLogic.insertPoint(into: identity, at: 0.5)
        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(updated[0], CGPoint(x: 0, y: 0))
        XCTAssertEqual(updated[1].x, 0.5)
        XCTAssertEqual(updated[1].y, 0.5, accuracy: 1e-9, "y must lie on the identity line")
        XCTAssertEqual(updated[2], CGPoint(x: 1, y: 1))
    }

    func testInsertPointTooCloseToEndpointIsRejected() {
        let nearLeft = CurveEditorLogic.insertPoint(into: identity, at: 0.0005)
        XCTAssertEqual(nearLeft, identity, "click hugging the left endpoint must not insert")
        let nearRight = CurveEditorLogic.insertPoint(into: identity, at: 0.9995)
        XCTAssertEqual(nearRight, identity, "click hugging the right endpoint must not insert")
    }

    func testInsertPointPreservesXOrdering() {
        var points = identity
        points = CurveEditorLogic.insertPoint(into: points, at: 0.3)
        points = CurveEditorLogic.insertPoint(into: points, at: 0.7)
        points = CurveEditorLogic.insertPoint(into: points, at: 0.5)
        let xs = points.map(\.x)
        XCTAssertEqual(xs, xs.sorted(), "x coordinates must remain monotonic after multiple inserts")
    }

    // MARK: - movePoint

    func testMoveEndpointLocksX() {
        let updated = CurveEditorLogic.movePoint(
            in: identity,
            at: 0,
            to: CGPoint(x: 0.4, y: 0.6)
        )
        XCTAssertEqual(updated[0].x, 0, "left endpoint x must not move")
        XCTAssertEqual(updated[0].y, 0.6, "left endpoint y must follow target")
        XCTAssertEqual(updated[1], CGPoint(x: 1, y: 1))
    }

    func testMoveInteriorPointClampsBetweenNeighbours() {
        let curve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.3, y: 0.3),
            CGPoint(x: 0.6, y: 0.6),
            CGPoint(x: 1, y: 1)
        ]
        // Try to move the middle handle past its right neighbour.
        let updated = CurveEditorLogic.movePoint(
            in: curve,
            at: 1,
            to: CGPoint(x: 0.9, y: 0.4)
        )
        XCTAssertLessThan(updated[1].x, curve[2].x, "x must clamp below the right neighbour")
        XCTAssertGreaterThan(updated[1].x, curve[0].x, "x must clamp above the left neighbour")
    }

    func testMoveClampsYToZeroOne() {
        let curve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1)
        ]
        let above = CurveEditorLogic.movePoint(
            in: curve,
            at: 1,
            to: CGPoint(x: 0.5, y: 1.5)
        )
        XCTAssertEqual(above[1].y, 1, "y must clamp to 1")
        let below = CurveEditorLogic.movePoint(
            in: curve,
            at: 1,
            to: CGPoint(x: 0.5, y: -0.3)
        )
        XCTAssertEqual(below[1].y, 0, "y must clamp to 0")
    }

    // MARK: - removePoint

    func testRemoveEndpointIsRejected() {
        let curve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.7),
            CGPoint(x: 1, y: 1)
        ]
        let removedLeft = CurveEditorLogic.removePoint(from: curve, at: 0)
        XCTAssertEqual(removedLeft, curve, "endpoint 0 must not be removable")
        let removedRight = CurveEditorLogic.removePoint(from: curve, at: 2)
        XCTAssertEqual(removedRight, curve, "endpoint last must not be removable")
    }

    func testRemoveInteriorPoint() {
        let curve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.7),
            CGPoint(x: 1, y: 1)
        ]
        let updated = CurveEditorLogic.removePoint(from: curve, at: 1)
        XCTAssertEqual(updated, identity)
    }

    func testCannotRemovePointFromIdentity() {
        let updated = CurveEditorLogic.removePoint(from: identity, at: 0)
        XCTAssertEqual(updated, identity, "removing from a 2-point curve is a no-op")
    }

    // MARK: - nearestHandle

    func testNearestHandleHitsWithinRadius() {
        let curve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1)
        ]
        let hit = CurveEditorLogic.nearestHandle(in: curve, to: CGPoint(x: 0.505, y: 0.50))
        XCTAssertEqual(hit, 1)
    }

    func testNearestHandleMissesOutsideRadius() {
        let hit = CurveEditorLogic.nearestHandle(
            in: identity,
            to: CGPoint(x: 0.5, y: 0.0),
            within: 0.05
        )
        XCTAssertNil(hit)
    }
}
