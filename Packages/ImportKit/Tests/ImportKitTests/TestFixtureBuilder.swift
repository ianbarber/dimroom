import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synthesises tiny JPEG fixtures at runtime so we don't have to commit
/// binary blobs. Everything here is deterministic in terms of the metadata
/// it writes — we don't pin the raw JPEG byte hash because ImageIO's
/// encoder output can drift across OS versions.
enum TestFixtureBuilder {

    struct ExifOptions {
        var dateTimeOriginal: String?   // EXIF format: "yyyy:MM:dd HH:mm:ss"
        var make: String?
        var model: String?
        var lensMake: String?
        var lensModel: String?
        var orientation: Int?           // 1-8
    }

    /// Writes a tiny grey JPEG with the requested EXIF/TIFF metadata embedded.
    /// Returns the URL it was written to.
    static func writeJPEG(
        width: Int = 48,
        height: Int = 32,
        exif: ExifOptions,
        to url: URL
    ) throws {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 128, count: width * height * bytesPerPixel)
        // Full alpha.
        for i in stride(from: 3, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = pixels.withUnsafeMutableBufferPointer({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerPixel * width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else {
            throw NSError(domain: "TestFixtureBuilder", code: 1)
        }
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "TestFixtureBuilder", code: 2)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "TestFixtureBuilder", code: 3)
        }

        var tiff: [CFString: Any] = [:]
        if let make = exif.make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model = exif.model { tiff[kCGImagePropertyTIFFModel] = model }

        var exifDict: [CFString: Any] = [:]
        if let dto = exif.dateTimeOriginal {
            exifDict[kCGImagePropertyExifDateTimeOriginal] = dto
        }
        if let lensMake = exif.lensMake {
            exifDict[kCGImagePropertyExifLensMake] = lensMake
        }
        if let lensModel = exif.lensModel {
            exifDict[kCGImagePropertyExifLensModel] = lensModel
        }

        var properties: [CFString: Any] = [:]
        if let orientation = exif.orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if !exifDict.isEmpty { properties[kCGImagePropertyExifDictionary] = exifDict }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "TestFixtureBuilder", code: 4)
        }
    }

    /// Writes raw bytes to a file at `url` — useful for RAW-extension tests
    /// where we only care about the extension branch, not decoding the file.
    static func writeBytes(_ bytes: [UInt8], to url: URL) throws {
        try Data(bytes).write(to: url)
    }
}
