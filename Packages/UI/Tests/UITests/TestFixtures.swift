import Catalog
import CoreGraphics
import Foundation
import ImageIO
import Previews
import UniformTypeIdentifiers

/// Helpers for building synthetic `Asset`s and pre-placing thumbnail
/// JPEGs where `PreviewStore.thumbnailURL(for:)` expects them.
///
/// Tests must not perform any real decoding, so we skip `PreviewStore`'s
/// generator entirely and write directly to the cache paths it serves.
enum TestFixtures {

    static func makeAsset(
        hash: String,
        filename: String = "test.jpg",
        captureDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        importedDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        width: Int = 800,
        height: Int = 600
    ) -> Asset {
        Asset(
            contentHash: hash,
            originalFilename: filename,
            captureDate: captureDate,
            importedDate: importedDate,
            sourceType: .digital,
            width: width,
            height: height,
            bytes: 123_456
        )
    }

    /// Write a solid-colour JPEG to the location `PreviewStore` would
    /// return for this asset's thumbnail. The file is addressed by
    /// sharded content-hash, matching `CachePaths.fileURL`.
    @discardableResult
    static func placeThumbnail(
        for asset: Asset,
        cacheDirectory: URL,
        color: (r: UInt8, g: UInt8, b: UInt8),
        width: Int = 256,
        height: Int = 256
    ) throws -> URL {
        let prefix = String(asset.contentHash.prefix(2))
        let dir = cacheDirectory.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash).thumb.jpg")
        try writeSolidColorJPEG(
            width: width,
            height: height,
            color: color,
            to: url
        )
        return url
    }

    /// Write a solid-colour JPEG at the preview path for this asset,
    /// matching the filename `PreviewStore.previewURL(for:)` resolves.
    /// Dimensions mimic a downscaled preview — bigger than a thumbnail,
    /// smaller than a full RAW — so snapshots exercise aspect-fit
    /// layout without decoding a 2048px image in the test process.
    @discardableResult
    static func placePreview(
        for asset: Asset,
        cacheDirectory: URL,
        color: (r: UInt8, g: UInt8, b: UInt8),
        width: Int = 800,
        height: Int = 600
    ) throws -> URL {
        let prefix = String(asset.contentHash.prefix(2))
        let dir = cacheDirectory.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash).preview.jpg")
        try writeSolidColorJPEG(
            width: width,
            height: height,
            color: color,
            to: url
        )
        return url
    }

    /// Write a solid-colour JPEG at the **display-tier** preview path
    /// (`<hash>.edit.preview.jpg`). Tests that need to prove a consumer
    /// reads master vs. display can lay down distinct master and display
    /// files with different dimensions or colours.
    @discardableResult
    static func placeDisplayPreview(
        for asset: Asset,
        cacheDirectory: URL,
        color: (r: UInt8, g: UInt8, b: UInt8),
        width: Int = 800,
        height: Int = 600
    ) throws -> URL {
        let prefix = String(asset.contentHash.prefix(2))
        let dir = cacheDirectory.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash).edit.preview.jpg")
        try writeSolidColorJPEG(
            width: width,
            height: height,
            color: color,
            to: url
        )
        return url
    }

    /// Public entry point used by rotate tests that need a real JPEG on
    /// disk for `PreviewStore.generate` to decode. Mirrors the internal
    /// helper used by `placeThumbnail` / `placePreview`.
    static func writeSolidJPEG(
        width: Int,
        height: Int,
        color: (r: UInt8, g: UInt8, b: UInt8),
        to url: URL
    ) throws {
        try writeSolidColorJPEG(width: width, height: height, color: color, to: url)
    }

    /// Write a JPEG split into four solid-colour quadrants (top-left,
    /// top-right, bottom-left, bottom-right; top-left buffer origin). Gives
    /// a stub "original" a known feature per quadrant so the magnifier's
    /// original→preview coordinate mapping can be asserted: a sample at a
    /// quadrant centre must yield that quadrant's colour (#376).
    static func writeQuadrantJPEG(
        width: Int,
        height: Int,
        colors: (
            tl: (r: UInt8, g: UInt8, b: UInt8),
            tr: (r: UInt8, g: UInt8, b: UInt8),
            bl: (r: UInt8, g: UInt8, b: UInt8),
            br: (r: UInt8, g: UInt8, b: UInt8)
        ),
        to url: URL
    ) throws {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for row in 0..<height {
            let top = row < height / 2
            for col in 0..<width {
                let left = col < width / 2
                let c = top ? (left ? colors.tl : colors.tr) : (left ? colors.bl : colors.br)
                let o = (row * width + col) * bytesPerPixel
                pixels[o] = c.r
                pixels[o + 1] = c.g
                pixels[o + 2] = c.b
                pixels[o + 3] = 255
            }
        }
        try encodeRGBA8JPEG(pixels: &pixels, width: width, height: height, to: url)
    }

    private static func writeSolidColorJPEG(
        width: Int,
        height: Int,
        color: (r: UInt8, g: UInt8, b: UInt8),
        to url: URL
    ) throws {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for row in 0..<height {
            for col in 0..<width {
                let o = (row * width + col) * bytesPerPixel
                pixels[o] = color.r
                pixels[o + 1] = color.g
                pixels[o + 2] = color.b
                pixels[o + 3] = 255
            }
        }
        try encodeRGBA8JPEG(pixels: &pixels, width: width, height: height, to: url)
    }

    /// Encode a premultiplied-last RGBA8 buffer (top-left origin) as a JPEG
    /// at `url`. Shared by the solid and quadrant writers.
    private static func encodeRGBA8JPEG(
        pixels: inout [UInt8],
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        let bytesPerPixel = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = pixels.withUnsafeMutableBufferPointer({ ptr in
            CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerPixel * width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }),
              let cg = ctx.makeImage() else {
            throw NSError(domain: "TestFixtures", code: 1)
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "TestFixtures", code: 2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixtures", code: 3)
        }
    }
}
