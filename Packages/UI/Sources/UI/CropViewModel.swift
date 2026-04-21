import Catalog
import CoreGraphics
import EditEngine
import Foundation

/// Drives the interactive crop overlay.
///
/// `cropRect` is stored in normalised 0…1 space with a top-left origin to
/// match the SwiftUI overlay. The DevelopViewModel converts to the image's
/// pixel extent at commit time.
@MainActor
public final class CropViewModel: ObservableObject {
    @Published public var isActive: Bool = false
    @Published public var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published public var cropAngle: Double = 0
    @Published public var selectedPreset: AspectRatioPreset = .free

    /// Aspect ratio of the image being edited; used for the `.original`
    /// preset. Caller must set this when activating.
    public private(set) var imageAspect: Double = 1.0

    private var previousCropRect: CGRect?
    private var previousCropAngle: Double?

    public init() {}

    /// Enter crop mode. Takes a snapshot of the current rect + angle so
    /// `cancel()` can revert.
    public func activate(cropRect: CGRect, angle: Double, imageAspect: Double) {
        self.previousCropRect = self.cropRect
        self.previousCropAngle = self.cropAngle
        self.imageAspect = imageAspect
        self.cropRect = cropRect
        self.cropAngle = angle
        self.isActive = true
    }

    /// Exit crop mode and return the committed rect + angle for the
    /// DevelopViewModel to write into EditState.
    public func commit() -> (CGRect, Double) {
        isActive = false
        previousCropRect = nil
        previousCropAngle = nil
        return (cropRect, cropAngle)
    }

    /// Exit crop mode and restore the snapshot taken at `activate`.
    public func cancel() {
        if let previousCropRect {
            cropRect = previousCropRect
        }
        if let previousCropAngle {
            cropAngle = previousCropAngle
        }
        previousCropRect = nil
        previousCropAngle = nil
        isActive = false
    }

    /// Update the crop rect, applying the active aspect-ratio preset and
    /// clamping to the 0…1 image bounds. The caller passes the handle
    /// `anchor` that must stay fixed (e.g. the opposite corner when
    /// dragging a handle).
    ///
    /// `overrideRatio` lets the caller bypass `selectedPreset` for a
    /// single drag — used by Shift-drag in `.free` mode to lock the
    /// current rect's aspect ratio without changing the saved preset.
    public func updateRect(_ rect: CGRect, anchor: CGPoint, overrideRatio: Double? = nil) {
        let ratio = overrideRatio ?? selectedPreset.ratio(imageAspect: imageAspect)
        let constrained = CropGeometry.constrain(
            rect: rect,
            to: ratio,
            anchor: anchor
        )
        cropRect = clampToUnit(constrained)
    }

    /// Reset the crop rect to the unit square (full frame) without
    /// disturbing the active preset or the snapshot taken at `activate`,
    /// so `cancel()` still reverts to whatever the user had before
    /// entering crop mode. Driven by the double-click gesture inside the
    /// crop overlay.
    public func resetRect() {
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// Translate the crop rect, clamping only to the 0…1 image bounds.
    /// Unlike `updateRect`, this never re-applies the aspect-ratio
    /// constraint — translation is shape-preserving by definition, and
    /// routing it through `CropGeometry.constrain` with a midpoint anchor
    /// would teleport the rect (the ratio branches tie and snap origin
    /// to `anchor - targetSize`).
    public func translateRect(_ rect: CGRect) {
        cropRect = clampToUnit(rect)
    }

    /// Set a new straighten angle. Clamped to -45…+45, then any
    /// `cropRect` that would spill into the blank corners of the rotated
    /// image is shrunk about its existing centre via
    /// `CropGeometry.fitCropToRotatedBounds` (current centre is kept so
    /// the crop doesn't jump away from the user's placement).
    public func setAngle(_ degrees: Double) {
        let clamped = CropGeometry.clampAngle(degrees)
        cropRect = CropGeometry.fitCropToRotatedBounds(cropRect: cropRect, angle: clamped)
        cropAngle = clamped
    }

    /// Apply the currently selected preset to the existing rect, keeping
    /// the crop centred. Used when the user picks a new preset.
    public func applyPreset(_ preset: AspectRatioPreset) {
        selectedPreset = preset
        guard let ratio = preset.ratio(imageAspect: imageAspect) else { return }
        let centre = CGPoint(x: cropRect.midX, y: cropRect.midY)
        // Build a centred rect with the target ratio that fits inside the
        // current rect's bounds.
        let w = cropRect.width
        let h = cropRect.height
        let targetW: CGFloat
        let targetH: CGFloat
        if w / CGFloat(ratio) <= h {
            targetW = w
            targetH = w / CGFloat(ratio)
        } else {
            targetH = h
            targetW = h * CGFloat(ratio)
        }
        let newRect = CGRect(
            x: centre.x - targetW / 2,
            y: centre.y - targetH / 2,
            width: targetW,
            height: targetH
        )
        cropRect = clampToUnit(newRect)
    }

    private func clampToUnit(_ rect: CGRect) -> CGRect {
        var r = rect
        if r.width > 1 { r.size.width = 1 }
        if r.height > 1 { r.size.height = 1 }
        if r.origin.x < 0 { r.origin.x = 0 }
        if r.origin.y < 0 { r.origin.y = 0 }
        if r.maxX > 1 { r.origin.x = 1 - r.width }
        if r.maxY > 1 { r.origin.y = 1 - r.height }
        return r
    }
}
