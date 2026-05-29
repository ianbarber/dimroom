import Catalog
import CoreImage
import XCTest
@testable import EditEngine

final class MagnifierRegionTests: XCTestCase {

    private let imageSize = CGSize(width: 400, height: 300)

    // MARK: - Centre

    func testCentreSampleIsCentred() {
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 0.5, y: 0.5),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 150, y: 100, width: 100, height: 100))
    }

    // MARK: - Edges (re-anchored inward, never past the border)

    func testTopLeftCornerSampleClampsToImageCorner() {
        // Top-left in screen coords (0,0) → the region hugs the
        // top-left of the image, which in CI coords is the top edge.
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 0, y: 0),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 200, width: 100, height: 100))
    }

    func testBottomRightCornerSampleClampsToImageCorner() {
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 1, y: 1),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 300, y: 0, width: 100, height: 100))
    }

    func testLeftEdgeSampleClampsX() {
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 0, y: 0.5),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.midY, 150)
    }

    func testRightEdgeSampleClampsX() {
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 1, y: 0.5),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect.maxX, 400)
    }

    func testRectAlwaysWithinBounds() {
        // Sweep a grid of sample points; the region must never leave the
        // image.
        for ix in 0...10 {
            for iy in 0...10 {
                let rect = MagnifierRegion.clampedSourceRect(
                    imageSize: imageSize,
                    sampleCenter: CGPoint(x: Double(ix) / 10, y: Double(iy) / 10),
                    regionSize: CGSize(width: 120, height: 90)
                )
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertLessThanOrEqual(rect.maxX, imageSize.width)
                XCTAssertLessThanOrEqual(rect.maxY, imageSize.height)
            }
        }
    }

    // MARK: - Zoom-driven region size

    func testZoomChangesRegionSize() {
        // A 200pt window: 1:1 covers 200px, 2:1 covers 100px.
        let oneToOne = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 0.5, y: 0.5),
            regionSize: CGSize(width: 200, height: 200)
        )
        let twoToOne = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 0.5, y: 0.5),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(oneToOne.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(twoToOne.size, CGSize(width: 100, height: 100))
    }

    // MARK: - Degenerate cases

    func testRegionLargerThanImageClampsToImage() {
        let tiny = CGSize(width: 50, height: 40)
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: tiny,
            sampleCenter: CGPoint(x: 0.5, y: 0.5),
            regionSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(rect, CGRect(origin: .zero, size: tiny))
    }

    func testZeroImageReturnsZeroRect() {
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: .zero,
            sampleCenter: CGPoint(x: 0.5, y: 0.5),
            regionSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, .zero)
    }

    func testOutOfRangeSampleCentreIsClamped() {
        let rect = MagnifierRegion.clampedSourceRect(
            imageSize: imageSize,
            sampleCenter: CGPoint(x: 5, y: -3),
            regionSize: CGSize(width: 100, height: 100)
        )
        // x clamps to 1 → right edge; y clamps to 0 → top edge.
        XCTAssertEqual(rect, CGRect(x: 300, y: 200, width: 100, height: 100))
    }

    // MARK: - renderRegion smoke test

    func testRenderRegionProducesRequestedPixelSize() {
        let context = CIContext()
        let source = makeGradientImage(width: 400, height: 300)
        let result = Renderer.renderRegion(
            source: source,
            editState: EditState(),
            context: context,
            sampleCenter: CGPoint(x: 0.5, y: 0.5),
            regionPixelSize: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(result.image?.width, 100)
        XCTAssertEqual(result.image?.height, 100)
        XCTAssertEqual(result.outputExtent.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(result.regionRect, CGRect(x: 150, y: 100, width: 100, height: 100))
    }

    func testRenderRegionClampsAtEdge() {
        let context = CIContext()
        let source = makeGradientImage(width: 400, height: 300)
        let result = Renderer.renderRegion(
            source: source,
            editState: EditState(),
            context: context,
            sampleCenter: CGPoint(x: 0, y: 0),
            regionPixelSize: CGSize(width: 100, height: 100)
        )
        // Region stays fully inside the image even at the corner.
        XCTAssertEqual(result.regionRect, CGRect(x: 0, y: 200, width: 100, height: 100))
        XCTAssertEqual(result.image?.width, 100)
        XCTAssertEqual(result.image?.height, 100)
    }
}
