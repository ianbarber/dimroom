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
    public var vibrance: Double
    public var saturation: Double

    // MARK: - Crop

    public var cropRect: CGRect?
    public var cropAngle: Double?

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
        vibrance: Double = 0,
        saturation: Double = 0,
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
        self.vibrance = vibrance
        self.saturation = saturation
        self.cropRect = cropRect
        self.cropAngle = cropAngle
    }
}
