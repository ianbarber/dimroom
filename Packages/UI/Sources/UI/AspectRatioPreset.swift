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

    /// Target width/height ratio for this preset. `nil` means no constraint
    /// (free crop). `original` uses the image's intrinsic aspect ratio.
    public func ratio(imageAspect: Double) -> Double? {
        switch self {
        case .free: return nil
        case .original: return imageAspect
        case .oneToOne: return 1.0
        case .fourToThree: return 4.0 / 3.0
        case .threeToTwo: return 3.0 / 2.0
        case .sixteenToNine: return 16.0 / 9.0
        case .fiveToFour: return 5.0 / 4.0
        }
    }
}
