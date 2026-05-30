import Catalog
import CoreImage
import CoreGraphics
import Foundation
import XCTest
@testable import EditEngine

/// Regression tests for #320: a `cropRect` authored against the ~2048px
/// master preview was fed straight into `cropped(to:)` on the full-res
/// original at export time, extracting a tiny corner ROI instead of the
/// framed region. The fix records `cropReferenceSize` on the `EditState`
/// and rescales the rect to whatever resolution is being rendered.
///
/// The fixtures here use a top-black / bottom-white split so an output
/// sampled at its centre is a deterministic colour, and the same crop is
/// rendered at two resolutions whose outputs must differ only in scale.
final class CropResolutionRenderTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    /// A crop authored against a 64² reference must render to a region
    /// proportional to whatever source resolution it's applied to. The
    /// 256² render's output extent must be exactly 4× the 64² render's —
    /// and both must sample to the same colour. With the #320 bug the
    /// 256² render crops a 32²-sized corner ROI and the extent assertion
    /// fails.
    func testCropScalesWithSourceResolution() {
        let reference = CGSize(width: 64, height: 64)

        // Display-space top-left quadrant → CI pixel space against the
        // 64² reference. Top-left in display space is the *top* (high y)
        // in CI space, which is the black half of the source.
        let display = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        let cropRect = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: reference
        )
        let state = EditState(cropRect: cropRect, cropReferenceSize: reference)

        let small = Renderer.render(
            source: makeVerticallySplitImage(width: 64, height: 64),
            editState: state
        )
        let large = Renderer.render(
            source: makeVerticallySplitImage(width: 256, height: 256),
            editState: state
        )

        // Crop fraction is 0.5 × 0.5 of each source.
        XCTAssertEqual(small.extent.width, 32, accuracy: 0.5)
        XCTAssertEqual(small.extent.height, 32, accuracy: 0.5)
        XCTAssertEqual(large.extent.width, 128, accuracy: 0.5)
        XCTAssertEqual(large.extent.height, 128, accuracy: 0.5)

        // The large render is exactly 4× the small one.
        XCTAssertEqual(large.extent.width / small.extent.width, 4, accuracy: 0.05)
        XCTAssertEqual(large.extent.height / small.extent.height, 4, accuracy: 0.05)

        // Both sample to black (the top half of the source).
        let smallPixel = samplePixel(
            image: small,
            x: Int(small.extent.width) / 2,
            y: Int(small.extent.height) / 2,
            context: ctx
        )
        let largePixel = samplePixel(
            image: large,
            x: Int(large.extent.width) / 2,
            y: Int(large.extent.height) / 2,
            context: ctx
        )
        XCTAssertEqual(smallPixel.r, 0, "small render should sample black, got \(smallPixel.r)")
        XCTAssertEqual(largePixel.r, 0, "large render should sample black, got \(largePixel.r)")
        XCTAssertEqual(smallPixel.r, largePixel.r, "renders must agree on sampled colour")
    }

    /// The bottom-left display quadrant (the white half) must likewise
    /// land on white at both resolutions — guards against the rescale
    /// drifting the rect into the wrong half.
    func testScaledCropSelectsCorrectHalf() {
        let reference = CGSize(width: 64, height: 64)
        let display = CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5)
        let cropRect = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: reference
        )
        let state = EditState(cropRect: cropRect, cropReferenceSize: reference)

        let large = Renderer.render(
            source: makeVerticallySplitImage(width: 256, height: 256),
            editState: state
        )

        XCTAssertEqual(large.extent.width, 128, accuracy: 0.5)
        let pixel = samplePixel(
            image: large,
            x: Int(large.extent.width) / 2,
            y: Int(large.extent.height) / 2,
            context: ctx
        )
        XCTAssertEqual(pixel.r, 255, "bottom-left quadrant should sample white, got \(pixel.r)")
    }

    /// A non-zero straighten angle must still scale with resolution. The
    /// rescale is applied relative to the pre-rotation extent, so the
    /// rotation→crop ordering is preserved and the large output stays 4×
    /// the small one.
    func testStraightenedCropScalesWithResolution() {
        let reference = CGSize(width: 64, height: 64)
        // A centred crop well inside the frame so the +10° rotation can't
        // pull a transparent corner into the sampled region.
        let display = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropRect = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: reference
        )
        let state = EditState(
            cropRect: cropRect,
            cropAngle: 10,
            cropReferenceSize: reference
        )

        let small = Renderer.render(
            source: makeVerticallySplitImage(width: 64, height: 64),
            editState: state
        )
        let large = Renderer.render(
            source: makeVerticallySplitImage(width: 256, height: 256),
            editState: state
        )

        XCTAssertEqual(large.extent.width / small.extent.width, 4, accuracy: 0.05)
        XCTAssertEqual(large.extent.height / small.extent.height, 4, accuracy: 0.05)
    }

    /// Legacy rows (no `cropReferenceSize`) keep the pre-#320 factor-1.0
    /// behaviour: the rect is applied as-is at whatever resolution it
    /// finds. Rendered at the resolution it was authored against, the
    /// output extent equals the rect's size.
    func testNilReferenceSizeUsesUnitScale() {
        let source = makeVerticallySplitImage(width: 64, height: 64)
        let cropRect = CGRect(x: 0, y: 32, width: 32, height: 32)
        let state = EditState(cropRect: cropRect) // cropReferenceSize defaults to nil

        let result = Renderer.render(source: source, editState: state)

        XCTAssertEqual(result.extent.width, 32, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 32, accuracy: 0.5)
    }

    // MARK: - Fixtures

    /// Top half black, bottom half white in CGImage row order. Converted to
    /// a CIImage the black rows land at high y (the CI "top").
    private func makeVerticallySplitImage(width: Int, height: Int) -> CIImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            let value: UInt8 = y < height / 2 ? 0 : 255
            for x in 0..<width {
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
}
