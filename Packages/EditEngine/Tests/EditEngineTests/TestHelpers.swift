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

/// Sample a rectangular patch of pixels from a CIImage as a flat row-major array.
///
/// One context.render call covers the whole rect — cheaper and more accurate than
/// looping over `samplePixel`, and avoids per-pixel filter graph rebuilds.
func samplePatch(image: CIImage, rect: CGRect, context: CIContext) -> [PixelRGBA] {
    let width = Int(rect.width)
    let height = Int(rect.height)
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    context.render(
        image,
        toBitmap: &buffer,
        rowBytes: bytesPerRow,
        bounds: rect,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    )
    var out: [PixelRGBA] = []
    out.reserveCapacity(width * height)
    for i in 0..<(width * height) {
        let o = i * 4
        out.append(PixelRGBA(r: buffer[o], g: buffer[o + 1], b: buffer[o + 2], a: buffer[o + 3]))
    }
    return out
}

/// Rec. 601 luma in the 0–255 scale. Used by NR tests to score smoothing of a
/// luma-jittered grey patch independent of any small chroma drift.
func luma(_ p: PixelRGBA) -> Double {
    0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)
}

/// Cheap chroma proxy. `B − R` swings directly under the `R = mid+j, B = mid−j`
/// jitter pattern used by the chrominance-NR test source while staying invariant
/// under uniform luma changes.
func chromaBR(_ p: PixelRGBA) -> Double {
    Double(p.b) - Double(p.r)
}

func mean(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    return xs.reduce(0, +) / Double(xs.count)
}

/// Population variance — same N before and after, so the unbiased correction
/// would just cancel out of any ratio comparison.
func variance(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let m = mean(xs)
    let sq = xs.reduce(0.0) { acc, x in
        let d = x - m
        return acc + d * d
    }
    return sq / Double(xs.count)
}

/// Create a noisy test image with deterministic, seeded per-pixel jitter.
///
/// `lumaJitter` (in 0–255 units) adds the same offset to all three channels per
/// pixel — producing luminance noise on a grey base. `chromaJitter` adds an
/// offset of `+j` to R and `−j` to B, leaving G alone, producing chroma noise
/// while keeping the per-pixel luma close to `baseLuma`.
///
/// The seeded LCG is pure Swift (`state &* 1103515245 &+ 12345`) so results are
/// reproducible on CI and dev machines without depending on `arc4random`.
func makeNoisyImage(
    width: Int = 64,
    height: Int = 64,
    baseLuma: UInt8 = 128,
    lumaJitter: Int = 0,
    chromaJitter: Int = 0,
    seed: UInt32 = 0xC0FFEE
) -> CIImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    var state: UInt32 = seed
    func nextRange(_ half: Int) -> Int {
        state = state &* 1_103_515_245 &+ 12_345
        if half == 0 { return 0 }
        let span = half * 2 + 1
        return Int(state >> 16) % span - half
    }

    func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }

    for y in 0..<height {
        for x in 0..<width {
            let lj = nextRange(lumaJitter)
            let cj = nextRange(chromaJitter)
            let base = Int(baseLuma)
            let r = clamp(base + lj + cj)
            let g = clamp(base + lj)
            let b = clamp(base + lj - cj)
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
