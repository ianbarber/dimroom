import CoreGraphics
import Foundation

/// Non-destructive edit parameters for a single asset.
///
/// A default-initialised `EditState` is identity — the image passes through unchanged.
public struct EditState: Codable, Sendable, Equatable {
    // MARK: - Tone

    public var exposure: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double

    // MARK: - White Balance

    public var temperature: Double
    public var tint: Double

    // MARK: - Presence

    public var clarity: Double
    public var sharpening: Double
    public var vibrance: Double
    public var saturation: Double

    // MARK: - Noise Reduction

    public var luminanceNoiseReduction: Double
    public var chrominanceNoiseReduction: Double

    // MARK: - Vignette

    public var vignetteAmount: Double
    public var vignetteRoundness: Double
    public var vignetteSoftness: Double

    // MARK: - HSL

    /// Per-range hue shift in the order [red, orange, yellow, green, aqua,
    /// blue, purple, magenta]. Each entry is -100…+100, identity 0.
    public var hueShift: [Double]
    /// Per-range saturation in the order above. -100 fully desaturates the
    /// range, +100 boosts; identity 0.
    public var hslSaturation: [Double]
    /// Per-range luminance in the order above. -100 darkens the range,
    /// +100 lightens; identity 0.
    public var hslLuminance: [Double]

    // MARK: - Curves

    /// Luminance tone curve. Identity is `[(0,0), (1,1)]`. Points must be
    /// monotonic in x, with x and y in `[0, 1]`.
    public var toneCurvePoints: [CGPoint]
    public var redCurvePoints: [CGPoint]
    public var greenCurvePoints: [CGPoint]
    public var blueCurvePoints: [CGPoint]

    // MARK: - Crop

    public var cropRect: CGRect?
    public var cropAngle: Double?

    public static let hslIdentity: [Double] = [0, 0, 0, 0, 0, 0, 0, 0]
    public static let identityCurve: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    public init(
        exposure: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        temperature: Double = 6500,
        tint: Double = 0,
        clarity: Double = 0,
        sharpening: Double = 0,
        vibrance: Double = 0,
        saturation: Double = 0,
        luminanceNoiseReduction: Double = 0,
        chrominanceNoiseReduction: Double = 0,
        vignetteAmount: Double = 0,
        vignetteRoundness: Double = 50,
        vignetteSoftness: Double = 50,
        hueShift: [Double] = EditState.hslIdentity,
        hslSaturation: [Double] = EditState.hslIdentity,
        hslLuminance: [Double] = EditState.hslIdentity,
        toneCurvePoints: [CGPoint] = EditState.identityCurve,
        redCurvePoints: [CGPoint] = EditState.identityCurve,
        greenCurvePoints: [CGPoint] = EditState.identityCurve,
        blueCurvePoints: [CGPoint] = EditState.identityCurve,
        cropRect: CGRect? = nil,
        cropAngle: Double? = nil
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.temperature = temperature
        self.tint = tint
        self.clarity = clarity
        self.sharpening = sharpening
        self.vibrance = vibrance
        self.saturation = saturation
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.chrominanceNoiseReduction = chrominanceNoiseReduction
        self.vignetteAmount = vignetteAmount
        self.vignetteRoundness = vignetteRoundness
        self.vignetteSoftness = vignetteSoftness
        self.hueShift = EditState.normalisedHSL(hueShift)
        self.hslSaturation = EditState.normalisedHSL(hslSaturation)
        self.hslLuminance = EditState.normalisedHSL(hslLuminance)
        self.toneCurvePoints = toneCurvePoints
        self.redCurvePoints = redCurvePoints
        self.greenCurvePoints = greenCurvePoints
        self.blueCurvePoints = blueCurvePoints
        self.cropRect = cropRect
        self.cropAngle = cropAngle
    }

    // MARK: - Codable

    // Hand-rolled decoder so existing catalog rows (written before sharpening,
    // vignette, HSL, and curves existed) decode without error — missing keys
    // fall back to identity defaults defined in `init(...)`.
    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint
        case clarity, sharpening, vibrance, saturation
        case luminanceNoiseReduction, chrominanceNoiseReduction
        case vignetteAmount, vignetteRoundness, vignetteSoftness
        case hueShift, hslSaturation, hslLuminance
        case toneCurvePoints, redCurvePoints, greenCurvePoints, blueCurvePoints
        case cropRect, cropAngle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            exposure: try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0,
            contrast: try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0,
            highlights: try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0,
            shadows: try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0,
            whites: try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0,
            blacks: try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0,
            temperature: try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500,
            tint: try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0,
            clarity: try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0,
            sharpening: try c.decodeIfPresent(Double.self, forKey: .sharpening) ?? 0,
            vibrance: try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0,
            saturation: try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0,
            luminanceNoiseReduction: try c.decodeIfPresent(Double.self, forKey: .luminanceNoiseReduction) ?? 0,
            chrominanceNoiseReduction: try c.decodeIfPresent(Double.self, forKey: .chrominanceNoiseReduction) ?? 0,
            vignetteAmount: try c.decodeIfPresent(Double.self, forKey: .vignetteAmount) ?? 0,
            vignetteRoundness: try c.decodeIfPresent(Double.self, forKey: .vignetteRoundness) ?? 50,
            vignetteSoftness: try c.decodeIfPresent(Double.self, forKey: .vignetteSoftness) ?? 50,
            hueShift: try c.decodeIfPresent([Double].self, forKey: .hueShift) ?? EditState.hslIdentity,
            hslSaturation: try c.decodeIfPresent([Double].self, forKey: .hslSaturation) ?? EditState.hslIdentity,
            hslLuminance: try c.decodeIfPresent([Double].self, forKey: .hslLuminance) ?? EditState.hslIdentity,
            toneCurvePoints: try c.decodeIfPresent([CGPoint].self, forKey: .toneCurvePoints) ?? EditState.identityCurve,
            redCurvePoints: try c.decodeIfPresent([CGPoint].self, forKey: .redCurvePoints) ?? EditState.identityCurve,
            greenCurvePoints: try c.decodeIfPresent([CGPoint].self, forKey: .greenCurvePoints) ?? EditState.identityCurve,
            blueCurvePoints: try c.decodeIfPresent([CGPoint].self, forKey: .blueCurvePoints) ?? EditState.identityCurve,
            cropRect: try c.decodeIfPresent(CGRect.self, forKey: .cropRect),
            cropAngle: try c.decodeIfPresent(Double.self, forKey: .cropAngle)
        )
    }

    /// Coerce a user-supplied HSL array back to length 8 by truncating or
    /// padding with zeros. Tolerates a future catalog row written by a
    /// different binary with a different range count.
    private static func normalisedHSL(_ values: [Double]) -> [Double] {
        if values.count == 8 { return values }
        var out = hslIdentity
        for i in 0..<min(values.count, 8) {
            out[i] = values[i]
        }
        return out
    }
}
