import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Helpers that materialise deterministic synthetic images for tests so
/// we don't have to commit binary fixtures to the repo.
///
/// Both the writer and the reader here operate directly on the pixel
/// buffer in **visual** (top-down) coordinates — row 0 is always the
/// visual top. Sidestepping `CGContext.fill` / `CGContext.draw` avoids
/// any confusion about Quartz y-up/y-down conventions for bitmap
/// contexts.
enum FixtureFactory {

    /// Write a JPEG with a bright red top-left quadrant and dark grey
    /// elsewhere. The red corner is used as a sentinel when checking
    /// rotation — after a 90° CW rotation the red should appear in the
    /// visual top-right.
    static func makeSyntheticJPEG(
        width: Int,
        height: Int,
        at url: URL
    ) throws {
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        // Fill grey, then stamp red into the top-left quadrant.
        for row in 0..<height {
            for col in 0..<width {
                let o = (row * width + col) * bytesPerPixel
                let isTopLeft = (row < height / 2) && (col < width / 2)
                pixels[o] = isTopLeft ? 255 : 51       // R
                pixels[o + 1] = isTopLeft ? 0 : 51     // G
                pixels[o + 2] = isTopLeft ? 0 : 51     // B
                pixels[o + 3] = 255                    // A
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = pixels.withUnsafeMutableBufferPointer({ ptr in
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
            throw NSError(domain: "FixtureFactory", code: 1)
        }
        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "FixtureFactory", code: 2)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "FixtureFactory", code: 3)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "FixtureFactory", code: 4)
        }
    }

    /// Read back the pixel dimensions of an image file via ImageIO.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// Load the image and produce a top-down pixel buffer whose row 0
    /// is the visual top.
    private static func readPixels(
        from url: URL
    ) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerPixel * width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, pixels)
    }

    /// Average colour of a rect specified in visual (top-left origin,
    /// y-down) coordinates.
    static func averageColor(
        of url: URL,
        in rect: CGRect
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let buffer = readPixels(from: url) else { return nil }
        let width = buffer.width
        let height = buffer.height

        let minX = max(0, Int(rect.origin.x))
        let maxX = min(width, Int(rect.origin.x + rect.width))
        let minY = max(0, Int(rect.origin.y))
        let maxY = min(height, Int(rect.origin.y + rect.height))
        guard maxX > minX, maxY > minY else { return nil }

        var totalR: Int = 0, totalG: Int = 0, totalB: Int = 0
        var count: Int = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                totalR += Int(buffer.pixels[offset])
                totalG += Int(buffer.pixels[offset + 1])
                totalB += Int(buffer.pixels[offset + 2])
                count += 1
            }
        }
        return (
            CGFloat(totalR) / CGFloat(count) / 255.0,
            CGFloat(totalG) / CGFloat(count) / 255.0,
            CGFloat(totalB) / CGFloat(count) / 255.0
        )
    }
}
