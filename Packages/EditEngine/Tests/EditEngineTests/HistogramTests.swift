import XCTest
import CoreImage
import CoreGraphics
@testable import EditEngine

final class HistogramTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    // MARK: - Solid colours

    func test_solid_black_fills_first_bin() {
        let image = makeSolidImage(r: 0, g: 0, b: 0, width: 100, height: 100)
        guard let h = Histogram.compute(from: image, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        XCTAssertEqual(h.binCount, 256)
        XCTAssertEqual(h.red[0], 10_000, accuracy: 2)
        XCTAssertEqual(h.green[0], 10_000, accuracy: 2)
        XCTAssertEqual(h.blue[0], 10_000, accuracy: 2)
        // All other bins zero.
        XCTAssertEqual(h.red[1..<256].reduce(0, +), 0)
        XCTAssertEqual(h.green[1..<256].reduce(0, +), 0)
        XCTAssertEqual(h.blue[1..<256].reduce(0, +), 0)
        // All pixels in shadow bin → high clipping.
        XCTAssertEqual(h.shadowClipping, .high)
        XCTAssertEqual(h.highlightClipping, .none)
    }

    func test_solid_white_fills_last_bin() {
        let image = makeSolidImage(r: 255, g: 255, b: 255, width: 100, height: 100)
        guard let h = Histogram.compute(from: image, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        XCTAssertEqual(h.red[255], 10_000, accuracy: 2)
        XCTAssertEqual(h.green[255], 10_000, accuracy: 2)
        XCTAssertEqual(h.blue[255], 10_000, accuracy: 2)
        XCTAssertEqual(h.red[0..<255].reduce(0, +), 0)
        XCTAssertEqual(h.highlightClipping, .high)
        XCTAssertEqual(h.shadowClipping, .none)
    }

    // MARK: - Gradient

    func test_horizontal_gradient_distributes_bins() {
        // 256×1 gradient: exactly one pixel per bin value 0…255.
        let image = makeGradientImage(width: 256, height: 1)
        guard let h = Histogram.compute(from: image, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        // Each bin should have ≈ 1 count; tolerate ±1 for rounding.
        let total = h.red.reduce(0, +)
        XCTAssertEqual(total, 256, accuracy: 2)
        // No single bin should dominate.
        XCTAssertLessThan(h.red.max()!, 5)
    }

    // MARK: - Clipping classification

    func test_no_clipping_for_fully_midtone_image() {
        let image = makeSolidImage(r: 128, g: 128, b: 128, width: 100, height: 100)
        guard let h = Histogram.compute(from: image, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        XCTAssertEqual(h.shadowClipping, .none)
        XCTAssertEqual(h.highlightClipping, .none)
    }

    func test_highlight_clipping_low_vs_high() {
        // 0.5% white pixels → .low
        let lowImg = makePartialClippingImage(
            width: 100, height: 100,
            clippedPixels: 50,
            clippedValue: 255
        )
        guard let lowH = Histogram.compute(from: lowImg, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        XCTAssertEqual(lowH.highlightClipping, .low)

        // 2% white pixels → .high
        let highImg = makePartialClippingImage(
            width: 100, height: 100,
            clippedPixels: 200,
            clippedValue: 255
        )
        guard let highH = Histogram.compute(from: highImg, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        XCTAssertEqual(highH.highlightClipping, .high)
    }

    func test_shadow_clipping_detected_above_threshold() {
        let image = makePartialClippingImage(
            width: 100, height: 100,
            clippedPixels: 200,
            clippedValue: 0
        )
        guard let h = Histogram.compute(from: image, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        XCTAssertEqual(h.shadowClipping, .high)
        XCTAssertEqual(h.highlightClipping, .none)
    }

    // MARK: - Luminance

    func test_luminance_for_grayscale_matches_channel() {
        let image = makeSolidImage(r: 128, g: 128, b: 128, width: 100, height: 100)
        guard let h = Histogram.compute(from: image, context: ctx) else {
            XCTFail("Histogram.compute returned nil")
            return
        }
        // For a solid mid-grey, luminance = (R+G+B)/3 per bin, so
        // bin 128 should have ≈ 10_000 and all others 0.
        XCTAssertEqual(h.luminance[128], 10_000, accuracy: 2)
        XCTAssertEqual(h.luminance.prefix(128).reduce(0, +), 0)
        XCTAssertEqual(h.luminance.suffix(from: 129).reduce(0, +), 0)
    }
}

// MARK: - Helpers

/// A solid-colour image with 8-bit sRGB channels.
private func makeSolidImage(r: UInt8, g: UInt8, b: UInt8, width: Int, height: Int) -> CIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            pixels[offset] = r
            pixels[offset + 1] = g
            pixels[offset + 2] = b
            pixels[offset + 3] = 255
        }
    }
    return imageFromPixels(pixels, width: width, height: height)
}

/// A width×height image where every pixel is (128,128,128) except the
/// first `clippedPixels` row-major entries, which are set to
/// (clippedValue, clippedValue, clippedValue). Used to verify that
/// clipping classification kicks in at the right threshold.
private func makePartialClippingImage(
    width: Int,
    height: Int,
    clippedPixels: Int,
    clippedValue: UInt8
) -> CIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            let index = y * width + x
            let v: UInt8 = index < clippedPixels ? clippedValue : 128
            pixels[offset] = v
            pixels[offset + 1] = v
            pixels[offset + 2] = v
            pixels[offset + 3] = 255
        }
    }
    return imageFromPixels(pixels, width: width, height: height)
}

private func imageFromPixels(_ pixels: [UInt8], width: Int, height: Int) -> CIImage {
    let data = Data(pixels)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let provider = CGDataProvider(data: data as CFData)!
    let cg = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
    // Use a linear options dict so CIImage doesn't assume working
    // colorspace conversion; keeps the 8-bit pixel values intact
    // through CIAreaHistogram.
    return CIImage(
        cgImage: cg,
        options: [.colorSpace: colorSpace]
    )
}
