import CoreGraphics
import XCTest
@testable import EditEngine

/// Tests for the top-left ⇄ Core-Image-pixel conversions that keep the
/// SwiftUI overlay and the Core Image renderer in sync. Regression
/// guard for #156 Bug 1: the overlay selects the top-left quadrant and
/// the renderer renders the bottom-left — a silent Y-flip mismatch.
final class CropOrientationTests: XCTestCase {

    // MARK: - normalizedTopLeftToCIPixel

    /// Canonical case: display-top-left quadrant of a 600×400 image.
    /// `(0, 0, 0.5, 0.5)` in display space → `(0, 200, 300, 200)` in
    /// Core Image space (origin bottom-left).
    func testTopLeftQuadrantFlipsToCoreImageBottomHalf() {
        let size = CGSize(width: 600, height: 400)
        let display = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)

        let pixel = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: size
        )

        XCTAssertEqual(pixel.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pixel.origin.y, 200, accuracy: 1e-9)
        XCTAssertEqual(pixel.width, 300, accuracy: 1e-9)
        XCTAssertEqual(pixel.height, 200, accuracy: 1e-9)
    }

    /// Display bottom-left quadrant maps to CI origin — the mirror of
    /// the canonical case, locks both halves of the flip.
    func testBottomLeftQuadrantFlipsToCoreImageOrigin() {
        let size = CGSize(width: 600, height: 400)
        let display = CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5)

        let pixel = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: size
        )

        XCTAssertEqual(pixel.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(pixel.origin.y, 0, accuracy: 1e-9)
        XCTAssertEqual(pixel.width, 300, accuracy: 1e-9)
        XCTAssertEqual(pixel.height, 200, accuracy: 1e-9)
    }

    /// A full-frame identity rect must stay at `(0, 0, W, H)` — the
    /// Y-flip of a 0-origin, H-height rect is itself.
    func testFullFrameIdentityConverts() {
        let size = CGSize(width: 1920, height: 1080)
        let display = CGRect(x: 0, y: 0, width: 1, height: 1)

        let pixel = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: size
        )

        XCTAssertEqual(pixel.origin.x, 0, accuracy: 1e-6)
        XCTAssertEqual(pixel.origin.y, 0, accuracy: 1e-6)
        XCTAssertEqual(pixel.width, 1920, accuracy: 1e-6)
        XCTAssertEqual(pixel.height, 1080, accuracy: 1e-6)
    }

    /// Sub-unit display rect with an off-square image — exercises both
    /// axes and non-trivial Y-flip arithmetic.
    func testSubPixelRectConverts() {
        let size = CGSize(width: 1000, height: 750)
        let display = CGRect(x: 0.1, y: 0.25, width: 0.4, height: 0.3)

        let pixel = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: size
        )

        XCTAssertEqual(pixel.origin.x, 100, accuracy: 1e-6)
        // display.maxY = 0.55, so CI.minY = (1 - 0.55) * 750 = 337.5
        XCTAssertEqual(pixel.origin.y, 337.5, accuracy: 1e-6)
        XCTAssertEqual(pixel.width, 400, accuracy: 1e-6)
        XCTAssertEqual(pixel.height, 225, accuracy: 1e-6)
    }

    // MARK: - Round trip

    func testNormalizedTopLeftToCIPixelRoundTrip() {
        let size = CGSize(width: 1920, height: 1080)
        let display = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)

        let pixel = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: size
        )
        let roundTrip = CropGeometry.ciPixelToNormalizedTopLeft(
            rect: pixel,
            imageSize: size
        )

        XCTAssertEqual(roundTrip.origin.x, display.origin.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.origin.y, display.origin.y, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.width, display.width, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.height, display.height, accuracy: 1e-9)
    }

    /// Sub-pixel round trip — ensures no precision loss at fractional
    /// coordinates typical of overlay drag output.
    func testRoundTripAtSubPixelSizes() {
        let size = CGSize(width: 1337, height: 977)
        let display = CGRect(x: 0.133, y: 0.271, width: 0.337, height: 0.411)

        let pixel = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: size
        )
        let roundTrip = CropGeometry.ciPixelToNormalizedTopLeft(
            rect: pixel,
            imageSize: size
        )

        XCTAssertEqual(roundTrip.origin.x, display.origin.x, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.origin.y, display.origin.y, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.width, display.width, accuracy: 1e-9)
        XCTAssertEqual(roundTrip.height, display.height, accuracy: 1e-9)
    }

    // MARK: - Degenerate

    func testCIPixelToNormalizedTopLeftDegenerateImageReturnsInput() {
        let size = CGSize(width: 0, height: 0)
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let out = CropGeometry.ciPixelToNormalizedTopLeft(
            rect: rect,
            imageSize: size
        )
        XCTAssertEqual(out, rect)
    }
}
