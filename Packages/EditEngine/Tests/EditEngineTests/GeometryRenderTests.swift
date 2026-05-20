import XCTest
import CoreImage
import Catalog
@testable import EditEngine

final class GeometryRenderTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    /// Vertical black/white stripe pattern. Each pixel column alternates so
    /// any sub-pixel scaling shift produces a visible difference through
    /// bilinear interpolation — useful for testing CA correction whose shift
    /// is fractional at typical image sizes.
    private func makeStripeImage(width: Int, height: Int) -> CIImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x % 2 == 0) ? 0 : 255
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
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

    // MARK: - Identity pass-through

    func testGeometryIdentityIsPassThrough() {
        let source = makeGradientImage()
        let state = EditState(
            perspectiveVertical: 0,
            perspectiveHorizontal: 0,
            perspectiveRotation: 0,
            chromaticAberration: false,
            lensVignette: false
        )
        let result = Renderer.render(source: source, editState: state)

        XCTAssertEqual(result.extent, source.extent)

        let mid = Int(source.extent.width) / 2
        let srcPx = samplePixel(image: source, x: mid, y: mid, context: ctx)
        let resPx = samplePixel(image: result, x: mid, y: mid, context: ctx)
        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }

    // MARK: - Keystone

    func testVerticalKeystoneChangesEdgePixels() {
        // Use a colour image so the warp visibly redistributes pixels and we
        // don't accidentally sample where the gradient is symmetric.
        let source = makeColorImage(width: 64, height: 64)
        let result = Renderer.render(
            source: source,
            editState: EditState(perspectiveVertical: 80)
        )

        // Top-row pixels should differ because the top edge is pulled inward.
        // Sample close to the corner where the inset is most visible.
        let topY = Int(source.extent.height) - 4
        let cornerX = 4
        let srcPx = samplePixel(image: source, x: cornerX, y: topY, context: ctx)
        let resPx = samplePixel(image: result, x: cornerX, y: topY, context: ctx)
        let differs = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(differs, "Vertical keystone should change top-corner pixels")
        XCTAssertEqual(result.extent, source.extent)
    }

    func testHorizontalKeystoneChangesEdgePixels() {
        let source = makeColorImage(width: 64, height: 64)
        let result = Renderer.render(
            source: source,
            editState: EditState(perspectiveHorizontal: 80)
        )

        // Right edge is pulled inward at +horizontal; sample near a right-edge corner.
        let rightX = Int(source.extent.width) - 4
        let topY = Int(source.extent.height) - 4
        let srcPx = samplePixel(image: source, x: rightX, y: topY, context: ctx)
        let resPx = samplePixel(image: result, x: rightX, y: topY, context: ctx)
        let differs = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(differs, "Horizontal keystone should change right-corner pixels")
        XCTAssertEqual(result.extent, source.extent)
    }

    func testRotationChangesCornerPixels() {
        let source = makeColorImage(width: 64, height: 64)
        let result = Renderer.render(
            source: source,
            editState: EditState(perspectiveRotation: 30)
        )

        // After a 30° rotation, what was the saturated-blue right half now
        // angles down into the bottom corner; sample the top-right corner,
        // which now sees pixels from the originally muted-red left half.
        let cornerX = Int(source.extent.width) - 4
        let cornerY = Int(source.extent.height) - 4
        let srcPx = samplePixel(image: source, x: cornerX, y: cornerY, context: ctx)
        let resPx = samplePixel(image: result, x: cornerX, y: cornerY, context: ctx)
        let differs = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(differs, "Rotation should change corner pixels")
        XCTAssertEqual(result.extent, source.extent)
    }

    // MARK: - Chromatic aberration

    func testChromaticAberrationOnChangesPixels() {
        // Alternating black/white vertical stripes — every neighbour pair
        // has a 255-step gradient so even sub-pixel per-channel scaling
        // shifts measurable amounts after bilinear interpolation.
        let source = makeStripeImage(width: 64, height: 64)
        let result = Renderer.render(
            source: source,
            editState: EditState(chromaticAberration: true)
        )

        // Find any pixel that differs. The scale is about the image centre
        // so we look away from centre where the radial shift is largest.
        var foundDifference = false
        for x in stride(from: 4, to: 60, by: 4) {
            let srcPx = samplePixel(image: source, x: x, y: 32, context: ctx)
            let resPx = samplePixel(image: result, x: x, y: 32, context: ctx)
            if srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b {
                foundDifference = true
                break
            }
        }
        XCTAssertTrue(foundDifference, "CA correction should change at least one pixel when enabled")
    }

    func testChromaticAberrationOffIsPassThrough() {
        let source = makeColorImage()
        let result = Renderer.render(
            source: source,
            editState: EditState(chromaticAberration: false)
        )
        let mid = Int(source.extent.width) / 2
        let srcPx = samplePixel(image: source, x: mid, y: mid, context: ctx)
        let resPx = samplePixel(image: result, x: mid, y: mid, context: ctx)
        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }

    // MARK: - Lens vignette

    func testLensVignetteOnBrightensCorners() {
        let source = makeMidGreyImage(width: 64, height: 64, value: 80)
        let result = Renderer.render(
            source: source,
            editState: EditState(lensVignette: true)
        )

        // Corner should be brighter than the source (inverted vignette).
        let cornerX = 2
        let cornerY = 2
        let srcPx = samplePixel(image: source, x: cornerX, y: cornerY, context: ctx)
        let resPx = samplePixel(image: result, x: cornerX, y: cornerY, context: ctx)
        XCTAssertGreaterThan(resPx.r, srcPx.r, "Lens vignette correction should lift corner brightness")
    }

    func testLensVignetteOffIsPassThrough() {
        let source = makeMidGreyImage()
        let result = Renderer.render(
            source: source,
            editState: EditState(lensVignette: false)
        )
        let cornerX = 2
        let cornerY = 2
        let srcPx = samplePixel(image: source, x: cornerX, y: cornerY, context: ctx)
        let resPx = samplePixel(image: result, x: cornerX, y: cornerY, context: ctx)
        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }
}
