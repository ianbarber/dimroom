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

        // Positive vertical insets the bottom edge, so the bottom corners move
        // and the source content there is displaced into the (transparent)
        // inset triangle. Sample close to a bottom corner where it's clearest.
        let bottomY = 4
        let cornerX = 4
        let srcPx = samplePixel(image: source, x: cornerX, y: bottomY, context: ctx)
        let resPx = samplePixel(image: result, x: cornerX, y: bottomY, context: ctx)
        let differs = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(differs, "Vertical keystone should change bottom-corner pixels")
        XCTAssertEqual(result.extent, source.extent)
    }

    func testHorizontalKeystoneChangesEdgePixels() {
        let source = makeColorImage(width: 64, height: 64)
        let result = Renderer.render(
            source: source,
            editState: EditState(perspectiveHorizontal: 80)
        )

        // Left edge is inset at +horizontal; sample near a left-edge corner.
        let leftX = 4
        let topY = Int(source.extent.height) - 4
        let srcPx = samplePixel(image: source, x: leftX, y: topY, context: ctx)
        let resPx = samplePixel(image: result, x: leftX, y: topY, context: ctx)
        let differs = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(differs, "Horizontal keystone should change left-corner pixels")
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

    /// Count the white-run width on a single image row: sample a full-width,
    /// 1px-high patch and count bright pixels (luma > 128). Pixels outside the
    /// warped quad read as transparent black, so they don't count.
    private func whiteRunWidth(in image: CIImage, atY y: Int) -> Int {
        let extent = image.extent
        let rect = CGRect(x: extent.minX, y: CGFloat(y), width: extent.width, height: 1)
        let row = samplePatch(image: image, rect: rect, context: ctx)
        return row.filter { luma($0) > 128 }.count
    }

    /// The issue's core ask: confirm positive vertical keystone *corrects*
    /// (rather than worsens) converging verticals, against a keystone-affected
    /// target. We use a synthetic looking-up building proxy — white verticals
    /// that converge toward the top — rather than a real/personal photo (per
    /// the fixtures rule). Correcting straightens the verticals, i.e. moves the
    /// top/bottom white-run ratio toward 1; a negative value must move it away,
    /// which pins the sign so a future regression can't pass silently.
    func testPositiveVerticalKeystoneStraightensConvergingVerticals() {
        let source = makeKeystoneTargetImage(width: 240, height: 240)

        // Sample a few rows in from each edge to dodge resampling fuzz right at
        // the warped quad's boundary.
        let topY = 240 - 12
        let bottomY = 12

        func gapRatio(_ image: CIImage) -> Double {
            let top = Double(whiteRunWidth(in: image, atY: topY))
            let bottom = Double(whiteRunWidth(in: image, atY: bottomY))
            XCTAssertGreaterThan(bottom, 0, "bottom row should contain white pixels")
            return top / bottom
        }

        let sourceRatio = gapRatio(source)
        let corrected = Renderer.render(
            source: source,
            editState: EditState(perspectiveVertical: 60)
        )
        let worsened = Renderer.render(
            source: source,
            editState: EditState(perspectiveVertical: -60)
        )
        let correctedRatio = gapRatio(corrected)
        let worsenedRatio = gapRatio(worsened)

        // Source converges toward the top: narrow top run, wide bottom → < 1.
        XCTAssertLessThan(sourceRatio, 1.0, "source should have converging verticals")

        // Positive vertical straightens: the ratio moves toward parallel (1).
        XCTAssertGreaterThan(
            correctedRatio, sourceRatio,
            "positive vertical keystone should straighten converging verticals"
        )
        XCTAssertLessThan(
            abs(1.0 - correctedRatio), abs(1.0 - sourceRatio),
            "corrected ratio should sit closer to parallel than the source"
        )

        // Negative vertical worsens the convergence — pins the sign.
        XCTAssertLessThan(
            worsenedRatio, sourceRatio,
            "negative vertical keystone should worsen the convergence"
        )
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

    func testChromaticAberrationKeepsGreenChannelBitExact() {
        // Stripe pattern: every column alternates 0/255 so neighbouring G
        // values differ by the full 8-bit range. Any sub-pixel sampling shift
        // on the G channel would produce intermediate values and fail this
        // assertion. The CA kernel must sample G at the unmodified destination
        // coordinate so it passes through untouched even while R/B are scaled.
        let source = makeStripeImage(width: 64, height: 64)
        let result = Renderer.render(
            source: source,
            editState: EditState(chromaticAberration: true)
        )

        // Sample the centre and four off-centre points where the radial scale
        // applied to R/B is largest — those are exactly the positions where a
        // mistaken G transform would show up.
        let samplePoints = [(32, 32), (8, 8), (56, 8), (8, 56), (56, 56)]
        for (x, y) in samplePoints {
            let srcPx = samplePixel(image: source, x: x, y: y, context: ctx)
            let resPx = samplePixel(image: result, x: x, y: y, context: ctx)
            XCTAssertEqual(
                srcPx.g, resPx.g,
                "G channel should be bit-exact with CA on at (\(x), \(y)): source=\(srcPx.g) result=\(resPx.g)"
            )
        }
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

    func testLensVignetteCentreChangeIsBelowTwoPercent() {
        let source = makeMidGreyImage(width: 64, height: 64, value: 128)
        let result = Renderer.render(
            source: source,
            editState: EditState(lensVignette: true)
        )
        let mid = Int(source.extent.width) / 2
        let srcPx = samplePixel(image: source, x: mid, y: mid, context: ctx)
        let resPx = samplePixel(image: result, x: mid, y: mid, context: ctx)
        let deltaR = abs(Int(resPx.r) - Int(srcPx.r))
        let deltaG = abs(Int(resPx.g) - Int(srcPx.g))
        let deltaB = abs(Int(resPx.b) - Int(srcPx.b))
        XCTAssertLessThan(Double(deltaR) / 255.0, 0.02, "Centre R changed by >= 2% with lens vignette enabled")
        XCTAssertLessThan(Double(deltaG) / 255.0, 0.02, "Centre G changed by >= 2% with lens vignette enabled")
        XCTAssertLessThan(Double(deltaB) / 255.0, 0.02, "Centre B changed by >= 2% with lens vignette enabled")
    }

    func testLensVignetteCornerToCentreRatioIncreases() {
        let source = makeMidGreyImage(width: 64, height: 64, value: 128)
        let off = Renderer.render(source: source, editState: EditState(lensVignette: false))
        let on = Renderer.render(source: source, editState: EditState(lensVignette: true))

        let mid = Int(source.extent.width) / 2
        let cornerX = 2
        let cornerY = 2

        let offCentre = samplePixel(image: off, x: mid, y: mid, context: ctx)
        let offCorner = samplePixel(image: off, x: cornerX, y: cornerY, context: ctx)
        let onCentre = samplePixel(image: on, x: mid, y: mid, context: ctx)
        let onCorner = samplePixel(image: on, x: cornerX, y: cornerY, context: ctx)

        let offRatio = Double(offCorner.r) / Double(offCentre.r)
        let onRatio = Double(onCorner.r) / Double(onCentre.r)
        XCTAssertGreaterThan(onRatio, offRatio, "Corner/centre ratio should increase when lens vignette correction is enabled")
    }
}
