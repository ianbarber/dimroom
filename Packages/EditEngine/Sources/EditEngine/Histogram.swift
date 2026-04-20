import CoreImage
import CoreGraphics
import Foundation

/// Level of clipping detected at the shadow or highlight end of the
/// tonal range. Thresholds are proportion of pixels landing in the
/// first (shadow) or last (highlight) bin.
public enum ClippingLevel: Equatable, Sendable {
    case none
    case low
    case high
}

/// Per-channel bin counts plus derived luminance and clipping info for
/// a single rendered image. Bin counts are integer pixel counts; the
/// sum across bins for a given channel equals the total pixel count of
/// the source image (within rounding tolerance).
public struct HistogramData: Equatable, Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    public let luminance: [Int]
    public let shadowClipping: ClippingLevel
    public let highlightClipping: ClippingLevel
    public let binCount: Int

    public init(
        red: [Int],
        green: [Int],
        blue: [Int],
        luminance: [Int],
        shadowClipping: ClippingLevel,
        highlightClipping: ClippingLevel,
        binCount: Int
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        self.shadowClipping = shadowClipping
        self.highlightClipping = highlightClipping
        self.binCount = binCount
    }
}

public enum Histogram {

    /// Clipping thresholds, as a fraction of total pixels landing in the
    /// shadow (bin 0) or highlight (last bin) bucket. A small amount of
    /// fringe clipping is unavoidable on most real photos; we only flag
    /// it at `.low` past 0.1% and `.high` past 1.0%.
    static let lowThreshold: Double = 0.001
    static let highThreshold: Double = 0.01

    /// Compute a per-channel histogram (plus an averaged luminance
    /// histogram and clipping indicators) for `image`, using
    /// `CIAreaHistogram` on the GPU.
    public static func compute(
        from image: CIImage,
        context: CIContext,
        bins: Int = 256
    ) -> HistogramData? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, bins > 0 else {
            return nil
        }

        guard let histogramFilter = CIFilter(name: "CIAreaHistogram") else {
            return nil
        }
        histogramFilter.setValue(image, forKey: kCIInputImageKey)
        histogramFilter.setValue(
            CIVector(cgRect: extent),
            forKey: kCIInputExtentKey
        )
        histogramFilter.setValue(bins, forKey: "inputCount")
        histogramFilter.setValue(1.0, forKey: "inputScale")

        guard let output = histogramFilter.outputImage else {
            return nil
        }

        // CIAreaHistogram emits a `bins × 1` RGBA float image where
        // each pixel's channel values are the fraction of input pixels
        // whose channel fell into that bin. Render linearly (no
        // colorspace conversion) so those fractions stay intact.
        var buffer = [Float](repeating: 0, count: bins * 4)
        let bounds = CGRect(x: 0, y: 0, width: bins, height: 1)
        context.render(
            output,
            toBitmap: &buffer,
            rowBytes: bins * 4 * MemoryLayout<Float>.size,
            bounds: bounds,
            format: .RGBAf,
            colorSpace: nil
        )

        let totalPixels = Int(extent.width) * Int(extent.height)
        let totalDouble = Double(totalPixels)

        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)
        var luminance = [Int](repeating: 0, count: bins)

        for bin in 0..<bins {
            let base = bin * 4
            let rCount = Int((Double(buffer[base]) * totalDouble).rounded())
            let gCount = Int((Double(buffer[base + 1]) * totalDouble).rounded())
            let bCount = Int((Double(buffer[base + 2]) * totalDouble).rounded())
            red[bin] = rCount
            green[bin] = gCount
            blue[bin] = bCount
            // Per-bin luminance is the mean of the three channel
            // counts at that bin. For grayscale images (R=G=B) this
            // equals the channel count, so a solid mid-grey fills bin
            // 128 in both RGB and luminance as expected.
            luminance[bin] = (rCount + gCount + bCount) / 3
        }

        let shadowFraction = totalPixels > 0
            ? Double(max(red[0], max(green[0], blue[0]))) / totalDouble
            : 0
        let highlightFraction = totalPixels > 0
            ? Double(max(red[bins - 1], max(green[bins - 1], blue[bins - 1]))) / totalDouble
            : 0

        return HistogramData(
            red: red,
            green: green,
            blue: blue,
            luminance: luminance,
            shadowClipping: classify(shadowFraction),
            highlightClipping: classify(highlightFraction),
            binCount: bins
        )
    }

    private static func classify(_ fraction: Double) -> ClippingLevel {
        if fraction >= highThreshold { return .high }
        if fraction >= lowThreshold { return .low }
        return .none
    }
}
