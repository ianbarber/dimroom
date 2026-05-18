import Catalog
import CoreGraphics
import EditEngine
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
    scalar("Perspective Vertical", \.perspectiveVertical, decimals: 0)
    scalar("Perspective Horizontal", \.perspectiveHorizontal, decimals: 0)
    scalar("Perspective Rotation", \.perspectiveRotation, decimals: 1)

    // Temperature uses absolute formatting with a K suffix.
    if base.temperature != next.temperature {
        changes.append(Change(label: "Temperature \(String(format: "%.0f", next.temperature))K"))
    }

    // Boolean flags get an "On" / "Off" suffix.
    func flag(_ name: String, _ keyPath: KeyPath<EditState, Bool>) {
        let before = base[keyPath: keyPath]
        let after = next[keyPath: keyPath]
        guard before != after else { return }
        changes.append(Change(label: "\(name) \(after ? "On" : "Off")"))
    }
    flag("Chromatic Aberration", \.chromaticAberration)
    flag("Lens Vignette", \.lensVignette)

    // HSL: each axis is an 8-array. Treat a change to a single band as
    // one logical change ("Hue (Red) +12"); a change spanning multiple
    // bands or axes rolls up to a generic "HSL" label so the count rule
    // below still picks it up as a single change.
    let hslDiffs: [(axis: String, label: String, base: [Double], next: [Double])] = [
        ("Hue", "Hue", base.hueShift, next.hueShift),
        ("Saturation", "HSL Saturation", base.hslSaturation, next.hslSaturation),
        ("Luminance", "Luminance", base.hslLuminance, next.hslLuminance),
    ]
    var hslSingleBand: (axis: String, range: HSLColorRange, value: Double)?
    var hslChangeCount = 0
    for diff in hslDiffs {
        for index in 0..<min(diff.base.count, diff.next.count) {
            guard diff.base[index] != diff.next[index] else { continue }
            hslChangeCount += 1
            if hslChangeCount == 1,
               let range = HSLColorRange(rawValue: index) {
                hslSingleBand = (axis: diff.axis, range: range, value: diff.next[index])
            } else {
                hslSingleBand = nil
            }
        }
    }
    if hslChangeCount == 1, let band = hslSingleBand {
        changes.append(Change(
            label: "\(band.axis) (\(band.range.displayName)) \(String(format: "%+.0f", band.value))"
        ))
    } else if hslChangeCount > 1 {
        changes.append(Change(label: "HSL"))
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
