import Catalog
import CoreGraphics
import Foundation

/// Build a short per-parameter label for an `.editSave` undo action
/// ("Exposure +2.00", "Temperature 5500K") by diffing `previous` and
/// `next`. Returns `nil` when zero or more than one logical parameter
/// changed, so callers can fall back to the generic "Edit" label.
///
/// Crop (rect + angle) is treated as a single logical parameter so
/// rotating a crop doesn't count as two changes.
///
/// Scalars are `Double` but values come from discrete-step sliders or
/// Codable round-trip in copy/paste, so `!=` is exact in practice. If a
/// future source introduces floating-point drift we'd report a spurious
/// single-parameter change; acceptable for now.
func editParameterDescription(previous: EditState?, next: EditState) -> String? {
    let base = previous ?? EditState()

    struct Change {
        let label: String
    }

    var changes: [Change] = []

    // Scalars with signed formatting.
    func scalar(_ name: String, _ keyPath: KeyPath<EditState, Double>, decimals: Int) {
        let before = base[keyPath: keyPath]
        let after = next[keyPath: keyPath]
        guard before != after else { return }
        let format = "%+.\(decimals)f"
        changes.append(Change(label: "\(name) \(String(format: format, after))"))
    }

    scalar("Exposure", \.exposure, decimals: 2)
    scalar("Contrast", \.contrast, decimals: 0)
    scalar("Highlights", \.highlights, decimals: 0)
    scalar("Shadows", \.shadows, decimals: 0)
    scalar("Whites", \.whites, decimals: 0)
    scalar("Blacks", \.blacks, decimals: 0)
    scalar("Tint", \.tint, decimals: 0)
    scalar("Clarity", \.clarity, decimals: 0)
    scalar("Sharpening", \.sharpening, decimals: 0)
    scalar("Vibrance", \.vibrance, decimals: 0)
    scalar("Saturation", \.saturation, decimals: 0)
    scalar("Luminance NR", \.luminanceNoiseReduction, decimals: 0)
    scalar("Chrominance NR", \.chrominanceNoiseReduction, decimals: 0)
    scalar("Vignette Amount", \.vignetteAmount, decimals: 0)
    scalar("Vignette Roundness", \.vignetteRoundness, decimals: 0)
    scalar("Vignette Softness", \.vignetteSoftness, decimals: 0)

    // Temperature uses absolute formatting with a K suffix.
    if base.temperature != next.temperature {
        changes.append(Change(label: "Temperature \(String(format: "%.0f", next.temperature))K"))
    }

    // Crop: rect + angle roll up into one logical change.
    if base.cropRect != next.cropRect || base.cropAngle != next.cropAngle {
        changes.append(Change(label: "Crop"))
    }

    // Curves: each channel reports as a single labelled change.
    if base.toneCurvePoints != next.toneCurvePoints {
        changes.append(Change(label: "Luminance Curve"))
    }
    if base.redCurvePoints != next.redCurvePoints {
        changes.append(Change(label: "Red Curve"))
    }
    if base.greenCurvePoints != next.greenCurvePoints {
        changes.append(Change(label: "Green Curve"))
    }
    if base.blueCurvePoints != next.blueCurvePoints {
        changes.append(Change(label: "Blue Curve"))
    }

    guard changes.count == 1 else { return nil }
    return changes[0].label
}
