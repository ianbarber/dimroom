import CoreGraphics
import DriveClient
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Harness-only downloader that synthesises a *real, decodable* 4-quadrant
/// JPEG so a Layer C flow can drive the magnifier's full-resolution
/// source-swap end-to-end. Installed by `DimroomApp` only when
/// `DIMROOM_HARNESS_STUB_DOWNLOADER=quadrant-original` is set, so production
/// never sees it.
///
/// Differs from the sibling stubs (`SlowChunkHarnessDownloader`,
/// `HoldUntilReleasedHarnessDownloader`) in one load-bearing way: those write
/// non-image filler bytes, so `DevelopViewModel.decodeOriginal`
/// (`CIImage(contentsOf:)`) returns `nil` and the magnifier stays on the
/// preview fallback. This one writes a genuine JPEG, so the decode succeeds,
/// `magnifierSource` swaps to the full-resolution original, and
/// `magnifierUsingPreviewFallback` clears — the property the Layer C flow
/// asserts.
///
/// Ignores `driveFileId`: the same payload is produced for every call — the
/// flow proves the source-swap fires, not Drive's byte stream. The four
/// quadrant colours meet at the centre (0.5, 0.5), so a magnifier screenshot
/// at that sample point shows the four-way cross.
struct QuadrantImageHarnessDownloader: OriginalsDownloader {
    /// Pixel dimensions of the synthesised original. Large enough that the
    /// magnifier's full-res region (≤200 px at 1:1) samples comfortably inside
    /// it without hitting the edges.
    static let payloadWidth = 1600
    static let payloadHeight = 1200

    /// Quadrant fill colours, 8-bit RGB. Distinct and saturated so a pixel
    /// sample at each quadrant centre is unambiguous even after JPEG's lossy
    /// round-trip. Named for their position in the rendered image.
    static let topLeftColor: (r: UInt8, g: UInt8, b: UInt8) = (220, 40, 40)      // red
    static let topRightColor: (r: UInt8, g: UInt8, b: UInt8) = (40, 200, 60)     // green
    static let bottomLeftColor: (r: UInt8, g: UInt8, b: UInt8) = (50, 90, 220)   // blue
    static let bottomRightColor: (r: UInt8, g: UInt8, b: UInt8) = (235, 205, 40) // yellow

    /// All four declared colours, for tests / pixel checks to match against.
    static let quadrantColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        topLeftColor, topRightColor, bottomLeftColor, bottomRightColor,
    ]

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let image = try Self.makeQuadrantImage()
        try Self.encodeJPEG(image, to: destinationURL)
        progress?(1.0)
    }

    /// Render the four-quadrant image into an RGBA8 bitmap context. Top-left of
    /// the *rendered image* is `topLeftColor`; CG's bottom-left origin means
    /// the "top" quadrants occupy the larger-y half of the context.
    static func makeQuadrantImage() throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: payloadWidth,
            height: payloadHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw QuadrantImageHarnessError.contextUnavailable
        }

        let halfW = CGFloat(payloadWidth) / 2
        let halfH = CGFloat(payloadHeight) / 2
        func fill(_ rect: CGRect, _ c: (r: UInt8, g: UInt8, b: UInt8)) {
            context.setFillColor(
                red: CGFloat(c.r) / 255,
                green: CGFloat(c.g) / 255,
                blue: CGFloat(c.b) / 255,
                alpha: 1
            )
            context.fill(rect)
        }
        fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH), topLeftColor)
        fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH), topRightColor)
        fill(CGRect(x: 0, y: 0, width: halfW, height: halfH), bottomLeftColor)
        fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH), bottomRightColor)

        guard let image = context.makeImage() else {
            throw QuadrantImageHarnessError.contextUnavailable
        }
        return image
    }

    /// JPEG-encode `image` to `url`. High quality so the flat quadrant centres
    /// stay close to the declared colours through JPEG's lossy round-trip.
    static func encodeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw QuadrantImageHarnessError.encodeFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw QuadrantImageHarnessError.encodeFailed
        }
    }
}

enum QuadrantImageHarnessError: Error {
    case contextUnavailable
    case encodeFailed
}
