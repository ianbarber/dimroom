import Catalog
import CoreImage
import CoreGraphics
import Foundation
import XCTest
@testable import EditEngine

/// End-to-end test wiring the new `normalizedTopLeftToCIPixel` helper
/// through `Renderer.render` — the test that would have caught #156
/// Bug 1 at pull-request time. Uses a vertically-split source image so
/// a Y-flip bug renders the opposite half and fails a pixel assertion.
final class CropOrientationRenderTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    /// Cropping the top-left quadrant of a top-black / bottom-white
    /// image must produce an all-black output. With the unfixed
    /// renderer (no top-left → CI Y-flip), the same overlay
    /// selection would render the bottom half and come back white.
    func testCroppedTopLeftQuadrantFromDisplayNormalised() {
        let source = makeVerticallySplitImage(width: 64, height: 64)
        let imageSize = source.extent.size

        // Display-space top-left quadrant: from the overlay's point of
        // view, the user selected the upper half of the left column.
        let display = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5)
        let cropRect = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: imageSize
        )

        let state = EditState(cropRect: cropRect)
        let result = Renderer.render(source: source, editState: state)

        // The output extent is the cropped rect's size, re-origined at
        // (0,0) — any pixel inside it must come from the top half of
        // the source, which is black.
        let centreX = Int(result.extent.width) / 2
        let centreY = Int(result.extent.height) / 2
        let pixel = samplePixel(image: result, x: centreX, y: centreY, context: ctx)

        XCTAssertEqual(pixel.r, 0, "expected black top half, got r=\(pixel.r)")
        XCTAssertEqual(pixel.g, 0, "expected black top half, got g=\(pixel.g)")
        XCTAssertEqual(pixel.b, 0, "expected black top half, got b=\(pixel.b)")
    }

    /// Mirror case: display-space bottom-left quadrant on the same
    /// image must come back white (bottom half of the source).
    func testCroppedBottomLeftQuadrantFromDisplayNormalised() {
        let source = makeVerticallySplitImage(width: 64, height: 64)
        let imageSize = source.extent.size

        let display = CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5)
        let cropRect = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: imageSize
        )

        let state = EditState(cropRect: cropRect)
        let result = Renderer.render(source: source, editState: state)

        let centreX = Int(result.extent.width) / 2
        let centreY = Int(result.extent.height) / 2
        let pixel = samplePixel(image: result, x: centreX, y: centreY, context: ctx)

        XCTAssertEqual(pixel.r, 255, "expected white bottom half, got r=\(pixel.r)")
        XCTAssertEqual(pixel.g, 255, "expected white bottom half, got g=\(pixel.g)")
        XCTAssertEqual(pixel.b, 255, "expected white bottom half, got b=\(pixel.b)")
    }

    // MARK: - Fixtures

    /// Top half black, bottom half white — the orientation-sensitive
    /// shape of this image is what makes the Y-flip bug visible.
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
