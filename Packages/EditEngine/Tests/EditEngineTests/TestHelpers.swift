import CoreImage
import CoreGraphics
import Foundation

/// Create a programmatic gradient image for testing.
///
/// Produces a horizontal grey ramp from black (left) to white (right).
/// The gradient is linear in sRGB space.
func makeGradientImage(width: Int = 64, height: Int = 64) -> CIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    for y in 0..<height {
        for x in 0..<width {
            let value = UInt8(Double(x) / Double(width - 1) * 255.0)
            let offset = y * bytesPerRow + x * bytesPerPixel
            pixels[offset] = value     // R
            pixels[offset + 1] = value // G
            pixels[offset + 2] = value // B
            pixels[offset + 3] = 255   // A
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

/// Create a colour ramp image for testing vibrance/saturation.
///
/// Produces an image where the left half is a muted red and the right half is a saturated blue.
func makeColorImage(width: Int = 64, height: Int = 64) -> CIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            if x < width / 2 {
                // Muted red (low saturation)
                pixels[offset] = 160     // R
                pixels[offset + 1] = 120 // G
                pixels[offset + 2] = 120 // B
            } else {
                // Saturated blue
                pixels[offset] = 0       // R
                pixels[offset + 1] = 0   // G
                pixels[offset + 2] = 240 // B
            }
            pixels[offset + 3] = 255     // A
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

/// Create a solid mid-grey image. Useful for vignette tests where we want the
/// source centre and corners to start at the same value so any difference
/// comes from the filter, not the source gradient.
func makeMidGreyImage(width: Int = 64, height: Int = 64, value: UInt8 = 128) -> CIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    for y in 0..<height {
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

/// Create a solid-colour test image with the given 8-bit RGB triple.
/// Used by HSL tests where each band is exercised against a pure
/// sample of its representative hue (e.g. pure red for the Red band).
func makeSolidColorImage(
    r: UInt8,
    g: UInt8,
    b: UInt8,
    width: Int = 64,
    height: Int = 64
) -> CIImage {
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

/// A single RGBA pixel value with 8-bit components.
struct PixelRGBA {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8
}

/// Sample a single pixel from a CIImage at the given coordinates.
///
/// Renders the image into a 1×1 bitmap at the specified location.
func samplePixel(image: CIImage, x: Int, y: Int, context: CIContext) -> PixelRGBA {
    let rect = CGRect(x: x, y: y, width: 1, height: 1)
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
        image,
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: rect,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
    return PixelRGBA(r: pixel[0], g: pixel[1], b: pixel[2], a: pixel[3])
}
