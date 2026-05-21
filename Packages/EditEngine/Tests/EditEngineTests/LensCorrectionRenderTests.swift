import Catalog
import CoreImage
import CoreGraphics
import Foundation
import XCTest
@testable import EditEngine

/// Renderer-level checks that a known lens profile drives the CA and lens
/// vignette stages to *different* output than the built-in nil-profile
/// placeholder. Magnitudes don't matter — only that the profile path is
/// reached and the parameters flow through.
final class LensCorrectionRenderTests: XCTestCase {

    private let ctx = CIContext()

    // MARK: - Helpers

    /// Magenta/green vertical stripe at the right edge — chosen because
    /// any per-channel radial scale displaces R relative to B and the
    /// sample then sees that as a colour shift on the stripe.
    private func makeStripeImage(width: Int = 64, height: Int = 64) -> CIImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if x == width - 6 {
                    pixels[offset]     = 255 // R
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 255 // B  (magenta)
                } else if x == width - 4 {
                    pixels[offset]     = 0
                    pixels[offset + 1] = 255 // G  (green)
                    pixels[offset + 2] = 0
                } else {
                    pixels[offset]     = 128
                    pixels[offset + 1] = 128
                    pixels[offset + 2] = 128
                }
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

    private func pixelsDiffer(_ a: PixelRGBA, _ b: PixelRGBA) -> Bool {
        Int(a.r) != Int(b.r) || Int(a.g) != Int(b.g) || Int(a.b) != Int(b.b)
    }

    private func channelDistance(_ a: PixelRGBA, _ b: PixelRGBA) -> Int {
        abs(Int(a.r) - Int(b.r))
            + abs(Int(a.g) - Int(b.g))
            + abs(Int(a.b) - Int(b.b))
    }

    // MARK: - CA correction

    func testChromaticAberrationCorrectionUsesProfileWhenProvided() {
        let source = makeStripeImage()
        let edit = EditState(chromaticAberration: true)

        let fallback = Renderer.render(source: source, editState: edit, lensProfile: nil)

        // _test_strong has ±1.5 % per-channel scale — well outside the
        // placeholder's ±0.5 %, so the rendered output must diverge.
        let strongProfile = LensProfile(
            caRedScale: 0.985,
            caBlueScale: 1.015,
            vignetteIntensity: -0.3,
            vignetteRadius: 1.5
        )
        let withProfile = Renderer.render(
            source: source,
            editState: edit,
            lensProfile: strongProfile
        )

        // Sample near the stripe — the per-channel radial scale moves R
        // and B differently between the two renders, so at least one
        // sampled pixel must differ between profile and placeholder.
        var differenceCount = 0
        var totalDistance = 0
        let y = Int(source.extent.height) / 2
        for x in stride(from: 50, to: 64, by: 1) {
            let placeholderPx = samplePixel(image: fallback, x: x, y: y, context: ctx)
            let profilePx = samplePixel(image: withProfile, x: x, y: y, context: ctx)
            if pixelsDiffer(placeholderPx, profilePx) {
                differenceCount += 1
            }
            totalDistance += channelDistance(placeholderPx, profilePx)
        }
        XCTAssertGreaterThan(
            differenceCount, 0,
            "Lens profile should produce pixel-level divergence from the nil-profile placeholder"
        )
        XCTAssertGreaterThan(
            totalDistance, 5,
            "Lens profile path must materially shift output (sum of channel deltas)"
        )
    }

    func testChromaticAberrationCorrectionFlagDisabledIgnoresProfile() {
        // If chromaticAberration is false, the renderer must skip the CA
        // stage entirely — passing a profile shouldn't sneak corrections
        // in through some other path.
        let source = makeStripeImage()
        let edit = EditState(chromaticAberration: false)
        let profile = LensProfile(
            caRedScale: 0.9, caBlueScale: 1.1,
            vignetteIntensity: -0.3, vignetteRadius: 1.5
        )
        let rendered = Renderer.render(source: source, editState: edit, lensProfile: profile)

        // Compare a stripe pixel against the source — should be identical
        // because no CA stage ran.
        let x = Int(source.extent.width) - 6
        let y = Int(source.extent.height) / 2
        let srcPx = samplePixel(image: source, x: x, y: y, context: ctx)
        let outPx = samplePixel(image: rendered, x: x, y: y, context: ctx)
        XCTAssertEqual(srcPx.r, outPx.r)
        XCTAssertEqual(srcPx.g, outPx.g)
        XCTAssertEqual(srcPx.b, outPx.b)
    }

    // MARK: - Vignette correction

    func testLensVignetteCorrectionUsesProfileWhenProvided() {
        let source = makeMidGreyImage()
        let edit = EditState(lensVignette: true)

        let fallback = Renderer.render(source: source, editState: edit, lensProfile: nil)

        // Stronger negative intensity than the placeholder's -0.3 — the
        // corner brightening at the edge must measurably exceed the
        // placeholder's lift.
        let strongProfile = LensProfile(
            caRedScale: 1.0,
            caBlueScale: 1.0,
            vignetteIntensity: -0.8,
            vignetteRadius: 2.0
        )
        let withProfile = Renderer.render(
            source: source,
            editState: edit,
            lensProfile: strongProfile
        )

        // Sample the corner — stronger -intensity should brighten the
        // corner more than the placeholder does.
        let cornerX = 2
        let cornerY = 2
        let placeholderPx = samplePixel(image: fallback, x: cornerX, y: cornerY, context: ctx)
        let profilePx = samplePixel(image: withProfile, x: cornerX, y: cornerY, context: ctx)
        XCTAssertGreaterThan(
            Int(profilePx.r), Int(placeholderPx.r),
            "Profile with stronger vignette intensity should brighten the corner more"
        )
    }

    func testLensVignetteCorrectionFlagDisabledIgnoresProfile() {
        let source = makeMidGreyImage()
        let edit = EditState(lensVignette: false)
        let profile = LensProfile(
            caRedScale: 1.0, caBlueScale: 1.0,
            vignetteIntensity: -0.9, vignetteRadius: 2.0
        )
        let rendered = Renderer.render(source: source, editState: edit, lensProfile: profile)

        let cornerX = 2
        let cornerY = 2
        let srcPx = samplePixel(image: source, x: cornerX, y: cornerY, context: ctx)
        let outPx = samplePixel(image: rendered, x: cornerX, y: cornerY, context: ctx)
        XCTAssertEqual(srcPx.r, outPx.r)
        XCTAssertEqual(srcPx.g, outPx.g)
        XCTAssertEqual(srcPx.b, outPx.b)
    }

    // MARK: - nil profile preserves placeholder path

    func testNilProfileMatchesUnchangedDefaultBehaviour() {
        // Sanity check: rendering with `lensProfile: nil` must produce
        // the same image as rendering without the parameter at all,
        // so existing callers that don't pass a profile keep their
        // pre-#253 behaviour byte-for-byte.
        let source = makeMidGreyImage()
        let edit = EditState(chromaticAberration: true, lensVignette: true)

        let defaultCall = Renderer.render(source: source, editState: edit)
        let explicitNil = Renderer.render(source: source, editState: edit, lensProfile: nil)

        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2
        let a = samplePixel(image: defaultCall, x: midX, y: midY, context: ctx)
        let b = samplePixel(image: explicitNil, x: midX, y: midY, context: ctx)
        XCTAssertEqual(a.r, b.r)
        XCTAssertEqual(a.g, b.g)
        XCTAssertEqual(a.b, b.b)
    }
}
