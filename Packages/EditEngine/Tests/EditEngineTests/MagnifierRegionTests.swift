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

    // MARK: - Full-resolution coordinate agreement (#376)
    //
    // The magnifier's value is that it samples the full-resolution
    // original, not the preview. The central correctness property is that
    // a scene feature at normalised sample point (x, y) lands at the patch
    // centre regardless of the source's pixel scale. These exercise that on
    // the real `renderRegion` path with exact in-memory colours.

    func testRenderRegionSamplesFeatureAtNormalisedPoint() {
        let context = CIContext()
        let source = makeQuadrantImage(
            width: 800, height: 600,
            tl: tlColor, tr: trColor, bl: blColor, br: brColor
        )

        // Each sample point sits at a quadrant centre, far from the
        // boundary cross at (0.5, 0.5), so the 100×100 patch is solidly
        // inside one quadrant. The sample point uses a top-left origin, so
        // a y-flip would swap TL↔BL / TR↔BR and read the wrong colour.
        let cases: [(point: CGPoint, expected: RGB, name: String)] = [
            (CGPoint(x: 0.25, y: 0.25), tlColor, "top-left"),
            (CGPoint(x: 0.75, y: 0.25), trColor, "top-right"),
            (CGPoint(x: 0.25, y: 0.75), blColor, "bottom-left"),
            (CGPoint(x: 0.75, y: 0.75), brColor, "bottom-right"),
        ]
        for c in cases {
            let region = Renderer.renderRegion(
                source: source,
                editState: EditState(),
                context: context,
                sampleCenter: c.point,
                regionPixelSize: CGSize(width: 100, height: 100)
            )
            guard let cg = region.image, let pixel = centrePixel(of: cg) else {
                XCTFail("renderRegion produced no patch for \(c.name)")
                continue
            }
            assertColor(pixel, equals: c.expected, tolerance: 3, name: c.name)
        }
    }

    func testReticleCentreIsScaleInvariant() {
        let context = CIContext()
        // Same scene at two resolutions; the larger is an exact 2× of the
        // smaller (both 4:3). The reticle is drawn over the preview while
        // the patch is cut from the original, so the region centre must map
        // to the same normalised location at both scales.
        let small = makeQuadrantImage(
            width: 400, height: 300,
            tl: tlColor, tr: trColor, bl: blColor, br: brColor
        )
        let large = makeQuadrantImage(
            width: 800, height: 600,
            tl: tlColor, tr: trColor, bl: blColor, br: brColor
        )
        // Off-centre and well inside the top-left quadrant at both scales,
        // so neither patch clamps against an edge or crosses a boundary.
        let sample = CGPoint(x: 0.3, y: 0.3)

        let regionSize = CGSize(width: 80, height: 80)
        let regionSmall = Renderer.renderRegion(
            source: small, editState: EditState(), context: context,
            sampleCenter: sample, regionPixelSize: regionSize
        )
        let regionLarge = Renderer.renderRegion(
            source: large, editState: EditState(), context: context,
            sampleCenter: sample, regionPixelSize: regionSize
        )

        let centreSmall = normalisedCentre(of: regionSmall)
        let centreLarge = normalisedCentre(of: regionLarge)
        XCTAssertEqual(centreSmall.x, centreLarge.x, accuracy: 0.001)
        XCTAssertEqual(centreSmall.y, centreLarge.y, accuracy: 0.001)
        // And the shared centre actually tracks the sample point: 0.3 from
        // the left, 0.3 from the top → 0.7 from the bottom in CI coords.
        XCTAssertEqual(centreLarge.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(centreLarge.y, 0.7, accuracy: 0.001)

        // The same feature (top-left quadrant) is sampled at both scales.
        if let pSmall = regionSmall.image.flatMap({ centrePixel(of: $0) }),
           let pLarge = regionLarge.image.flatMap({ centrePixel(of: $0) }) {
            assertColor(pSmall, equals: tlColor, tolerance: 3, name: "small/top-left")
            assertColor(pLarge, equals: tlColor, tolerance: 3, name: "large/top-left")
        } else {
            XCTFail("renderRegion produced no patch at one or both scales")
        }
    }

    // MARK: - Coordinate-agreement helpers

    private struct RGB: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private var tlColor: RGB { RGB(r: 200, g: 50, b: 50) }
    private var trColor: RGB { RGB(r: 50, g: 200, b: 50) }
    private var blColor: RGB { RGB(r: 50, g: 50, b: 200) }
    private var brColor: RGB { RGB(r: 200, g: 200, b: 50) }

    /// Build an in-memory four-quadrant image (one solid colour per
    /// quadrant) with a top-left buffer origin, so a sampled patch carries
    /// a known per-quadrant feature. No JPEG round-trip → exact colours.
    private func makeQuadrantImage(
        width: Int, height: Int,
        tl: RGB, tr: RGB, bl: RGB, br: RGB
    ) -> CIImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for row in 0..<height {
            let top = row < height / 2
            for col in 0..<width {
                let left = col < width / 2
                let c = top ? (left ? tl : tr) : (left ? bl : br)
                let o = row * bytesPerRow + col * bytesPerPixel
                pixels[o] = c.r
                pixels[o + 1] = c.g
                pixels[o + 2] = c.b
                pixels[o + 3] = 255
            }
        }
        let data = Data(pixels)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let provider = CGDataProvider(data: data as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return CIImage(cgImage: cgImage)
    }

    /// Read the centre pixel of a CGImage by drawing it into a known sRGB
    /// bitmap context.
    private func centrePixel(of cgImage: CGImage) -> RGB? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let o = ((h / 2) * w + (w / 2)) * 4
        return RGB(r: ptr[o], g: ptr[o + 1], b: ptr[o + 2])
    }

    /// Normalised centre of `regionRect` within `outputExtent` — the same
    /// quantity the view model converts into the on-screen reticle.
    private func normalisedCentre(of region: Renderer.RegionRender) -> CGPoint {
        let ext = region.outputExtent
        let r = region.regionRect
        return CGPoint(
            x: (r.midX - ext.minX) / ext.width,
            y: (r.midY - ext.minY) / ext.height
        )
    }

    private func assertColor(
        _ actual: RGB,
        equals expected: RGB,
        tolerance: Int,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            abs(Int(actual.r) - Int(expected.r)), tolerance,
            "\(name) R channel: got \(actual), expected \(expected)", file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            abs(Int(actual.g) - Int(expected.g)), tolerance,
            "\(name) G channel: got \(actual), expected \(expected)", file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            abs(Int(actual.b) - Int(expected.b)), tolerance,
            "\(name) B channel: got \(actual), expected \(expected)", file: file, line: line
        )
    }
}
