import CoreGraphics
import XCTest
@testable import EditEngine

final class CropGeometryTests: XCTestCase {

    // MARK: - Normalised ↔ pixel

    func testNormalizedToPixelRoundTripFourK() {
        let size = CGSize(width: 4000, height: 3000)
        let normalised = CGRect(x: 0.25, y: 0.0, width: 0.5, height: 1.0)
        let pixel = CropGeometry.normalizedToPixel(rect: normalised, imageSize: size)
        XCTAssertEqual(pixel.origin.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(pixel.origin.y, 0, accuracy: 1e-6)
        XCTAssertEqual(pixel.width, 2000, accuracy: 1e-6)
        XCTAssertEqual(pixel.height, 3000, accuracy: 1e-6)

        let roundTrip = CropGeometry.pixelToNormalized(rect: pixel, imageSize: size)
        XCTAssertEqual(roundTrip.origin.x, normalised.origin.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.origin.y, normalised.origin.y, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.width, normalised.width, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.height, normalised.height, accuracy: 1e-9)
    }

    func testNormalizedToPixelRoundTripFullHD() {
        let size = CGSize(width: 1920, height: 1080)
        let normalised = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        let pixel = CropGeometry.normalizedToPixel(rect: normalised, imageSize: size)
        XCTAssertEqual(pixel.origin.x, 192, accuracy: 1e-6)
        XCTAssertEqual(pixel.origin.y, 216, accuracy: 1e-6)
        XCTAssertEqual(pixel.width, 1536, accuracy: 1e-6)
        XCTAssertEqual(pixel.height, 648, accuracy: 1e-6)

        let roundTrip = CropGeometry.pixelToNormalized(rect: pixel, imageSize: size)
        XCTAssertEqual(roundTrip, normalised)
    }

    func testNormalizedToPixelUnitImage() {
        let size = CGSize(width: 1, height: 1)
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let pixel = CropGeometry.normalizedToPixel(rect: rect, imageSize: size)
        XCTAssertEqual(pixel, rect)
    }

    func testPixelToNormalizedDegenerateImageReturnsInput() {
        let size = CGSize(width: 0, height: 0)
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let normalised = CropGeometry.pixelToNormalized(rect: rect, imageSize: size)
        XCTAssertEqual(normalised, rect)
    }

    // MARK: - Aspect ratio constraint

    func testConstrainOneToOneAnchoredAtBottomRight() {
        // Starting rect 0.4 x 0.2, constrain to 1:1 anchored at the
        // bottom-right corner (so resizing shrinks from the top-left).
        let rect = CGRect(x: 0.0, y: 0.0, width: 0.4, height: 0.2)
        let anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        let constrained = CropGeometry.constrain(rect: rect, to: 1.0, anchor: anchor)

        // 1:1 should match the shorter dimension (height=0.2) → a 0.2×0.2 rect.
        XCTAssertEqual(constrained.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(constrained.height, 0.2, accuracy: 1e-9)
        // Bottom-right anchor must be preserved.
        XCTAssertEqual(constrained.maxX, rect.maxX, accuracy: 1e-9)
        XCTAssertEqual(constrained.maxY, rect.maxY, accuracy: 1e-9)
    }

    func testConstrainThreeToTwoAnchoredAtTopLeft() {
        // Rect 0.9 x 0.4. With 3:2 anchored top-left, we expect height
        // to grow to 0.9/1.5 = 0.6 (taller than original), which would
        // exceed bounds — but `constrain` picks the smaller-dimension
        // branch, so we get width = 0.4*1.5 = 0.6 and height = 0.4.
        let rect = CGRect(x: 0.0, y: 0.0, width: 0.9, height: 0.4)
        let anchor = CGPoint(x: rect.minX, y: rect.minY)
        let ratio = 3.0 / 2.0
        let constrained = CropGeometry.constrain(rect: rect, to: ratio, anchor: anchor)

        XCTAssertEqual(constrained.width / constrained.height, ratio, accuracy: 1e-9)
        // Top-left anchor preserved.
        XCTAssertEqual(constrained.minX, rect.minX, accuracy: 1e-9)
        XCTAssertEqual(constrained.minY, rect.minY, accuracy: 1e-9)
    }

    /// Anchor at the top-right corner: the opposite (bottom-left)
    /// handle was dragged. The right edge stays fixed and the rect
    /// grows leftward + downward.
    func testConstrainAnchoredAtTopRight() {
        let rect = CGRect(x: 0.1, y: 0.0, width: 0.6, height: 0.4)
        let anchor = CGPoint(x: rect.maxX, y: rect.minY)
        let constrained = CropGeometry.constrain(rect: rect, to: 1.0, anchor: anchor)

        XCTAssertEqual(constrained.width, constrained.height, accuracy: 1e-9)
        // Right edge preserved — anchor is on the right.
        XCTAssertEqual(constrained.maxX, rect.maxX, accuracy: 1e-9)
        // Top edge preserved — anchor is at the top.
        XCTAssertEqual(constrained.minY, rect.minY, accuracy: 1e-9)
    }

    /// Anchor at the bottom-left corner: the opposite (top-right)
    /// handle was dragged. The left edge stays fixed and the rect
    /// grows rightward + upward.
    func testConstrainAnchoredAtBottomLeft() {
        let rect = CGRect(x: 0.0, y: 0.1, width: 0.6, height: 0.4)
        let anchor = CGPoint(x: rect.minX, y: rect.maxY)
        let constrained = CropGeometry.constrain(rect: rect, to: 1.0, anchor: anchor)

        XCTAssertEqual(constrained.width, constrained.height, accuracy: 1e-9)
        // Left edge preserved — anchor is on the left.
        XCTAssertEqual(constrained.minX, rect.minX, accuracy: 1e-9)
        // Bottom edge preserved — anchor is at the bottom.
        XCTAssertEqual(constrained.maxY, rect.maxY, accuracy: 1e-9)
    }

    func testConstrainSixteenToNineProducesExactRatio() {
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let anchor = CGPoint(x: rect.midX, y: rect.midY)
        let ratio = 16.0 / 9.0
        let constrained = CropGeometry.constrain(rect: rect, to: ratio, anchor: anchor)
        XCTAssertEqual(constrained.width / constrained.height, ratio, accuracy: 1e-9)
    }

    func testConstrainWithNilRatioReturnsRectUnchanged() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let constrained = CropGeometry.constrain(
            rect: rect,
            to: nil,
            anchor: CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(constrained, rect)
    }

    // MARK: - Angle clamp

    func testClampAngleAtBoundaries() {
        XCTAssertEqual(CropGeometry.clampAngle(0), 0)
        XCTAssertEqual(CropGeometry.clampAngle(45), 45)
        XCTAssertEqual(CropGeometry.clampAngle(-45), -45)
    }

    func testClampAngleClampsNegativeBeyondRange() {
        XCTAssertEqual(CropGeometry.clampAngle(-50), -45)
        XCTAssertEqual(CropGeometry.clampAngle(-180), -45)
    }

    func testClampAngleClampsPositiveBeyondRange() {
        XCTAssertEqual(CropGeometry.clampAngle(60), 45)
        XCTAssertEqual(CropGeometry.clampAngle(90), 45)
    }

    // MARK: - fitCropToRotatedBounds

    func testFitCropToRotatedBoundsAtZeroIsIdentity() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.5)
        let fitted = CropGeometry.fitCropToRotatedBounds(cropRect: rect, angle: 0)
        XCTAssertEqual(fitted, rect)
    }

    func testFitCropToRotatedBoundsAt15DegreesShrinksRect() {
        let rect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let fitted = CropGeometry.fitCropToRotatedBounds(cropRect: rect, angle: 15)

        // Strictly smaller than the input.
        XCTAssertLessThan(fitted.width, rect.width)
        XCTAssertLessThan(fitted.height, rect.height)

        // Still centred.
        XCTAssertEqual(fitted.midX, rect.midX, accuracy: 1e-9)
        XCTAssertEqual(fitted.midY, rect.midY, accuracy: 1e-9)

        // Projection onto the rotated axes must fit within the unit
        // square — this is the defining property of an inscribed rect.
        let theta = 15.0 * .pi / 180.0
        let projX = fitted.width * cos(theta) + fitted.height * sin(theta)
        let projY = fitted.width * sin(theta) + fitted.height * cos(theta)
        XCTAssertLessThanOrEqual(projX, 1.0 + 1e-6)
        XCTAssertLessThanOrEqual(projY, 1.0 + 1e-6)
    }

    func testFitCropToRotatedBoundsNegativeAngleSameAsPositive() {
        let rect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let positive = CropGeometry.fitCropToRotatedBounds(cropRect: rect, angle: 15)
        let negative = CropGeometry.fitCropToRotatedBounds(cropRect: rect, angle: -15)
        XCTAssertEqual(positive, negative)
    }

    func testFitCropToRotatedBoundsLeavesSmallCropAlone() {
        // A 0.2x0.2 crop centred in the unit square should not shrink
        // at 15° because it already fits inside the rotated square.
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let fitted = CropGeometry.fitCropToRotatedBounds(cropRect: rect, angle: 15)
        XCTAssertEqual(fitted, rect)
    }

    // MARK: - rotationAngle

    /// A quarter-turn about the centre returns ±90. In SwiftUI's y-down
    /// space a move from the 3-o'clock point (+x) to the 6-o'clock point
    /// (+y, visually *below* centre) is a clockwise sweep, so it returns
    /// +90 — the same sign a positive straighten slider produces.
    func testRotationAngleQuarterTurnClockwiseIsPositive() {
        let centre = CGPoint(x: 100, y: 100)
        let from = CGPoint(x: 200, y: 100) // 3 o'clock
        let to = CGPoint(x: 100, y: 200)   // 6 o'clock (y-down → below)
        let angle = CropGeometry.rotationAngle(center: centre, from: from, to: to)
        XCTAssertEqual(angle, 90, accuracy: 1e-9)
    }

    /// The opposite sweep (3 o'clock → 12 o'clock, counter-clockwise in
    /// y-down space) returns −90.
    func testRotationAngleQuarterTurnCounterClockwiseIsNegative() {
        let centre = CGPoint(x: 100, y: 100)
        let from = CGPoint(x: 200, y: 100) // 3 o'clock
        let to = CGPoint(x: 100, y: 0)     // 12 o'clock (y-down → above)
        let angle = CropGeometry.rotationAngle(center: centre, from: from, to: to)
        XCTAssertEqual(angle, -90, accuracy: 1e-9)
    }

    /// Swapping `from` and `to` negates the swept angle.
    func testRotationAngleIsAntisymmetric() {
        let centre = CGPoint(x: 50, y: 50)
        let a = CGPoint(x: 90, y: 40)
        let b = CGPoint(x: 70, y: 95)
        let forward = CropGeometry.rotationAngle(center: centre, from: a, to: b)
        let backward = CropGeometry.rotationAngle(center: centre, from: b, to: a)
        XCTAssertEqual(forward, -backward, accuracy: 1e-9)
    }

    func testRotationAngleZeroLengthMoveReturnsZero() {
        let centre = CGPoint(x: 10, y: 10)
        let p = CGPoint(x: 40, y: 25)
        XCTAssertEqual(CropGeometry.rotationAngle(center: centre, from: p, to: p), 0)
    }

    func testRotationAnglePointAtCentreReturnsZero() {
        let centre = CGPoint(x: 10, y: 10)
        XCTAssertEqual(
            CropGeometry.rotationAngle(center: centre, from: centre, to: CGPoint(x: 40, y: 25)),
            0
        )
    }

    /// The result stays in (−180, 180] — a near-half-turn does not wrap to
    /// a large value.
    func testRotationAngleNormalisesToShortWayRound() {
        let centre = CGPoint(x: 0, y: 0)
        let from = CGPoint(x: 10, y: 1)    // just below the +x axis (small +)
        let to = CGPoint(x: 10, y: -1)     // just above the +x axis (small −)
        let angle = CropGeometry.rotationAngle(center: centre, from: from, to: to)
        XCTAssertLessThan(abs(angle), 30)
        XCTAssertLessThan(angle, 0)
    }

    // MARK: - snapAngle

    func testSnapAngleToFifteenDegreeIncrements() {
        XCTAssertEqual(CropGeometry.snapAngle(7, toIncrement: 15), 0, accuracy: 1e-9)
        XCTAssertEqual(CropGeometry.snapAngle(8, toIncrement: 15), 15, accuracy: 1e-9)
        XCTAssertEqual(CropGeometry.snapAngle(-8, toIncrement: 15), -15, accuracy: 1e-9)
        XCTAssertEqual(CropGeometry.snapAngle(22, toIncrement: 15), 15, accuracy: 1e-9)
        XCTAssertEqual(CropGeometry.snapAngle(23, toIncrement: 15), 30, accuracy: 1e-9)
        XCTAssertEqual(CropGeometry.snapAngle(0, toIncrement: 15), 0, accuracy: 1e-9)
    }

    func testSnapAngleNonPositiveIncrementReturnsInput() {
        XCTAssertEqual(CropGeometry.snapAngle(13.7, toIncrement: 0), 13.7)
        XCTAssertEqual(CropGeometry.snapAngle(13.7, toIncrement: -15), 13.7)
    }
}
