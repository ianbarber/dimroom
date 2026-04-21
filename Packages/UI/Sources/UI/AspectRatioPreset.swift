import Foundation

/// Fixed aspect-ratio choices for the crop tool sidebar picker.
public enum AspectRatioPreset: String, CaseIterable, Identifiable, Sendable {
    case free
    case original
    case oneToOne
    case fourToThree
    case threeToTwo
    case sixteenToNine
    case fiveToFour

    public var id: String { rawValue }

    /// Display label for the picker.
    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .oneToOne: return "1:1"
        case .fourToThree: return "4:3"
        case .threeToTwo: return "3:2"
        case .sixteenToNine: return "16:9"
        case .fiveToFour: return "5:4"
        }
    }

    /// Target width/height ratio *in the normalised 0…1 crop space*,
    /// derived from the preset's pixel-space ratio and the source
    /// image's aspect. `nil` means no constraint (free crop).
    ///
    /// Users pick "1:1" expecting a pixel-square crop. Because
    /// `cropRect` is stored in normalised coordinates, the crop is
    /// pixel-square only when `w_norm / h_norm == 1 / imageAspect`.
    /// The conversion is `normalisedRatio = pixelRatio / imageAspect`;
    /// `.original` collapses to 1.0 (same pixel shape as the source),
    /// and `.oneToOne` on a portrait image returns >1 so the
    /// normalised rect is wider than tall to land at a pixel square.
    public func ratio(imageAspect: Double) -> Double? {
        let pixelRatio: Double
        switch self {
        case .free: return nil
        case .original: pixelRatio = imageAspect
        case .oneToOne: pixelRatio = 1.0
        case .fourToThree: pixelRatio = 4.0 / 3.0
        case .threeToTwo: pixelRatio = 3.0 / 2.0
        case .sixteenToNine: pixelRatio = 16.0 / 9.0
        case .fiveToFour: pixelRatio = 5.0 / 4.0
        }
        guard imageAspect > 0 else { return nil }
        return pixelRatio / imageAspect
    }
}
