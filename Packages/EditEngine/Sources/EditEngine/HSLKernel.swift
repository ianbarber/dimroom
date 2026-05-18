import CoreGraphics
import CoreImage
import Foundation

/// Which HSL axis a slider drag adjusts: hue rotation, saturation scale,
/// or luminance offset. Used by the UI panel's segmented picker and by
/// the harness `setEditArrayParameter` command's parameter name.
public enum HSLAxis: String, CaseIterable, Sendable {
    case hue
    case saturation
    case luminance
}

/// One of the eight fixed colour ranges the HSL panel exposes. The order
/// here (`Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta`)
/// matches the array index used in `EditState.hueShift / hslSaturation /
/// hslLuminance`. Each band carries a representative `CGColor` so the UI
/// can tint its slider track.
public enum HSLColorRange: Int, CaseIterable, Sendable, Identifiable {
    case red = 0
    case orange = 1
    case yellow = 2
    case green = 3
    case aqua = 4
    case blue = 5
    case purple = 6
    case magenta = 7

    public var id: Int { rawValue }

    /// Centre hue in degrees for the cosine-falloff weight kernel.
    public var hueDegrees: Double {
        switch self {
        case .red: return 0
        case .orange: return 30
        case .yellow: return 60
        case .green: return 120
        case .aqua: return 180
        case .blue: return 240
        case .purple: return 270
        case .magenta: return 300
        }
    }

    public var displayName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .magenta: return "Magenta"
        }
    }

    /// RGB triple used to tint the slider track in the HSL panel. Values
    /// are picked at a moderate saturation/lightness so the track stays
    /// readable on a dark sidebar.
    public var representativeRGB: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red: return (0.86, 0.20, 0.20)
        case .orange: return (0.92, 0.55, 0.18)
        case .yellow: return (0.90, 0.84, 0.20)
        case .green: return (0.35, 0.75, 0.30)
        case .aqua: return (0.25, 0.78, 0.85)
        case .blue: return (0.25, 0.45, 0.90)
        case .purple: return (0.55, 0.35, 0.85)
        case .magenta: return (0.85, 0.30, 0.70)
        }
    }
}

/// Wraps a deprecated-but-functional `CIColorKernel(source:)` so the
/// Renderer can apply HSL adjustments in a single GPU pass. The kernel
/// reads each pixel, converts to HSL, computes cosine-falloff weights
/// for the eight fixed band centres, applies the weighted sum of
/// per-band hue / saturation / luminance parameters, and converts back
/// to RGB.
///
/// Inline kernel source avoids bundling a `.ci.metallib` resource into
/// the SPM target. The deprecation warning on `init(source:)` is
/// acceptable: the Metal-kernel alternative would require a custom build
/// step for each platform/architecture.
enum HSLKernel {

    /// Half-width in degrees of each band's cosine-falloff weight curve.
    /// At distance == halfWidth a band's weight is zero; at distance == 0
    /// it is one. Chosen to overlap adjacent named hues (30° apart) while
    /// leaving distant hues unaffected.
    static let halfWidthDegrees: Double = 60.0

    /// Compiled-once kernel instance. Returns `nil` if the kernel source
    /// fails to compile (only possible from a bug in the source text).
    static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    /// Apply the kernel to `image` with the given per-band parameter
    /// arrays. Each array must be length 8 in the
    /// [red, orange, yellow, green, aqua, blue, purple, magenta] order.
    ///
    /// Falls back to returning `image` unchanged when the kernel failed
    /// to compile — the user still sees the rest of the edit pipeline.
    static func apply(
        _ image: CIImage,
        hueShift: [Double],
        saturation: [Double],
        luminance: [Double]
    ) -> CIImage {
        guard let kernel else { return image }
        let hueA = CIVector(x: hueShift[0], y: hueShift[1], z: hueShift[2], w: hueShift[3])
        let hueB = CIVector(x: hueShift[4], y: hueShift[5], z: hueShift[6], w: hueShift[7])
        let satA = CIVector(x: saturation[0], y: saturation[1], z: saturation[2], w: saturation[3])
        let satB = CIVector(x: saturation[4], y: saturation[5], z: saturation[6], w: saturation[7])
        let lumA = CIVector(x: luminance[0], y: luminance[1], z: luminance[2], w: luminance[3])
        let lumB = CIVector(x: luminance[4], y: luminance[5], z: luminance[6], w: luminance[7])
        let halfWidth = NSNumber(value: halfWidthDegrees)

        let arguments: [Any] = [image, hueA, hueB, satA, satB, lumA, lumB, halfWidth]
        let extent = image.extent
        guard let output = kernel.apply(extent: extent, arguments: arguments) else {
            return image
        }
        return output.cropped(to: extent)
    }

    /// CI Kernel Language source for the per-pixel HSL transform. The
    /// per-band block is unrolled eight times to avoid CIKL array
    /// declarations, which have inconsistent support across compiler
    /// versions.
    ///
    /// Mapping summary:
    /// - Hue shift: ±100 → ±30° rotation of the band's hue.
    /// - Saturation: ±100 maps asymmetrically — +100 → 1.5×, -100 → 0×
    ///   (matches the global saturation slider's behaviour).
    /// - Luminance: ±100 → ±0.4 offset on the HSL `L` axis, clamped.
    private static let source: String = """
    kernel vec4 dimroomHSL(__sample s,
                           vec4 hueA, vec4 hueB,
                           vec4 satA, vec4 satB,
                           vec4 lumA, vec4 lumB,
                           float halfWidth) {
        float r = s.r;
        float g = s.g;
        float b = s.b;
        float a = s.a;

        float maxC = max(max(r, g), b);
        float minC = min(min(r, g), b);
        float L = (maxC + minC) * 0.5;
        float delta = maxC - minC;
        float S = 0.0;
        float H = 0.0;
        if (delta > 0.00001) {
            if (L > 0.5) {
                S = delta / (2.0 - maxC - minC);
            } else {
                S = delta / (maxC + minC);
            }
            if (maxC == r) {
                H = (g - b) / delta;
                if (g < b) H += 6.0;
            } else if (maxC == g) {
                H = (b - r) / delta + 2.0;
            } else {
                H = (r - g) / delta + 4.0;
            }
            H = H * 60.0;
        }

        float pi = 3.14159265358979;
        float hueShift = 0.0;
        float satShift = 0.0;
        float lumShift = 0.0;
        float d;
        float w;

        d = abs(H - 0.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueA.x;
            satShift += w * satA.x;
            lumShift += w * lumA.x;
        }

        d = abs(H - 30.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueA.y;
            satShift += w * satA.y;
            lumShift += w * lumA.y;
        }

        d = abs(H - 60.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueA.z;
            satShift += w * satA.z;
            lumShift += w * lumA.z;
        }

        d = abs(H - 120.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueA.w;
            satShift += w * satA.w;
            lumShift += w * lumA.w;
        }

        d = abs(H - 180.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueB.x;
            satShift += w * satB.x;
            lumShift += w * lumB.x;
        }

        d = abs(H - 240.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueB.y;
            satShift += w * satB.y;
            lumShift += w * lumB.y;
        }

        d = abs(H - 270.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueB.z;
            satShift += w * satB.z;
            lumShift += w * lumB.z;
        }

        d = abs(H - 300.0);
        if (d > 180.0) d = 360.0 - d;
        if (d < halfWidth) {
            w = 0.5 * (cos(pi * d / halfWidth) + 1.0);
            hueShift += w * hueB.w;
            satShift += w * satB.w;
            lumShift += w * lumB.w;
        }

        H = H + hueShift * 0.3;
        if (H < 0.0) H += 360.0;
        if (H >= 360.0) H -= 360.0;

        satShift = clamp(satShift, -100.0, 100.0);
        float satScale;
        if (satShift >= 0.0) {
            satScale = 1.0 + satShift / 200.0;
        } else {
            satScale = 1.0 + satShift / 100.0;
        }
        S = clamp(S * satScale, 0.0, 1.0);

        lumShift = clamp(lumShift, -100.0, 100.0);
        L = clamp(L + lumShift * 0.004, 0.0, 1.0);

        if (S < 0.00001) {
            return vec4(L, L, L, a);
        }

        float q;
        if (L < 0.5) {
            q = L * (1.0 + S);
        } else {
            q = L + S - L * S;
        }
        float p = 2.0 * L - q;

        float Hn = H / 360.0;
        float tr = Hn + 1.0 / 3.0;
        float tg = Hn;
        float tb = Hn - 1.0 / 3.0;

        if (tr > 1.0) tr -= 1.0;
        if (tr < 0.0) tr += 1.0;
        if (tg > 1.0) tg -= 1.0;
        if (tg < 0.0) tg += 1.0;
        if (tb > 1.0) tb -= 1.0;
        if (tb < 0.0) tb += 1.0;

        float rOut;
        if (tr < 1.0 / 6.0) {
            rOut = p + (q - p) * 6.0 * tr;
        } else if (tr < 0.5) {
            rOut = q;
        } else if (tr < 2.0 / 3.0) {
            rOut = p + (q - p) * (2.0 / 3.0 - tr) * 6.0;
        } else {
            rOut = p;
        }

        float gOut;
        if (tg < 1.0 / 6.0) {
            gOut = p + (q - p) * 6.0 * tg;
        } else if (tg < 0.5) {
            gOut = q;
        } else if (tg < 2.0 / 3.0) {
            gOut = p + (q - p) * (2.0 / 3.0 - tg) * 6.0;
        } else {
            gOut = p;
        }

        float bOut;
        if (tb < 1.0 / 6.0) {
            bOut = p + (q - p) * 6.0 * tb;
        } else if (tb < 0.5) {
            bOut = q;
        } else if (tb < 2.0 / 3.0) {
            bOut = p + (q - p) * (2.0 / 3.0 - tb) * 6.0;
        } else {
            bOut = p;
        }

        return vec4(rOut, gOut, bOut, a);
    }
    """
}
