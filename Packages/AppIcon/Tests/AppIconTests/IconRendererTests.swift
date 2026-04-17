import CoreGraphics
import Foundation
@testable import AppIcon
import XCTest

final class IconRendererTests: XCTestCase {

    private let requiredSizes = [16, 32, 64, 128, 256, 512, 1024]

    func test_render_returns_correct_dimensions_for_all_sizes() {
        for size in requiredSizes {
            let image = AppIconRenderer.render(pixelSize: size)
            XCTAssertEqual(image.width, size, "Width mismatch for size \(size)")
            XCTAssertEqual(image.height, size, "Height mismatch for size \(size)")
        }
    }

    func test_png_round_trip_preserves_dimensions() throws {
        for size in requiredSizes {
            let image = AppIconRenderer.render(pixelSize: size)
            let data = IconWriter.pngData(from: image)
            XCTAssertGreaterThan(data.count, 0, "PNG data empty for size \(size)")

            let provider = CGDataProvider(data: data as CFData)!
            let decoded = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )!
            XCTAssertEqual(decoded.width, size, "Decoded width mismatch for size \(size)")
            XCTAssertEqual(decoded.height, size, "Decoded height mismatch for size \(size)")
        }
    }

    func test_rendered_image_is_not_solid_colour() {
        let image = AppIconRenderer.render(pixelSize: 128)
        let width = image.width
        let height = image.height

        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            XCTFail("Could not access pixel data")
            return
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        let firstR = ptr[0]
        let firstG = ptr[1]
        let firstB = ptr[2]
        var allSame = true

        outer: for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if ptr[offset] != firstR || ptr[offset + 1] != firstG || ptr[offset + 2] != firstB {
                    allSame = false
                    break outer
                }
            }
        }

        XCTAssertFalse(allSame, "Rendered icon appears to be a solid colour — drawing may be broken")
    }
}
