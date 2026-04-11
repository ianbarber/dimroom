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
        color: (r: UInt8, g: UInt8, b: UInt8)
    ) throws -> URL {
        let prefix = String(asset.contentHash.prefix(2))
        let dir = cacheDirectory.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash).thumb.jpg")
        try writeSolidColorJPEG(
            width: 256,
            height: 256,
            color: color,
            to: url
        )
        return url
    }

    static func placeThumbnailFromData(
        for asset: Asset,
        cacheDirectory: URL,
        sourceURL: URL
    ) throws -> URL {
        let prefix = String(asset.contentHash.prefix(2))
        let dir = cacheDirectory.appendingPathComponent(prefix, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(asset.contentHash).thumb.jpg")
        try FileManager.default.copyItem(at: sourceURL, to: url)
        return url
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
