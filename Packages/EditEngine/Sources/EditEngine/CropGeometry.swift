import CoreGraphics
import Foundation

/// Pure geometry utilities for the interactive crop tool.
///
/// All functions are stateless and take their inputs by value. They do not
/// know about the UI overlay or the renderer — they only manipulate rects
/// and angles. The UI layer binds these to drag gestures; the renderer is
/// independent.
public enum CropGeometry {

    // MARK: - Normalised ↔ pixel

    /// Convert a crop rect in 0…1 normalised space into pixel coordinates
    /// for the given image size. Origin convention is preserved — callers
    /// must pass the same convention both ways.
    public static func normalizedToPixel(rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.origin.x * imageSize.width,
            y: rect.origin.y * imageSize.height,
            width: rect.size.width * imageSize.width,
            height: rect.size.height * imageSize.height
        )
    }

    /// Inverse of `normalizedToPixel`. Degenerate (zero-sized) images
    /// return the input unchanged.
    public static func pixelToNormalized(rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        return CGRect(
            x: rect.origin.x / imageSize.width,
            y: rect.origin.y / imageSize.height,
            width: rect.size.width / imageSize.width,
            height: rect.size.height / imageSize.height
        )
    }

    /// Convert a crop rect from display-space (top-left origin, normalised
    /// 0…1) into Core Image pixel coordinates (bottom-left origin).
    ///
    /// SwiftUI overlays use a top-left origin so a `(0, 0, 0.5, 0.5)`
    /// selection means "the top-left quadrant." Core Image's coordinate
    /// system has Y growing upward, so the same quadrant lives at
    /// `(0, H/2, W/2, H/2)`. Without this flip the renderer would crop
    /// the bottom-left quadrant instead — the visible symptom of #156's
    /// region mismatch bug.
    public static func normalizedTopLeftToCIPixel(rect: CGRect, imageSize: CGSize) -> CGRect {
        let pixel = normalizedToPixel(rect: rect, imageSize: imageSize)
        return CGRect(
            x: pixel.origin.x,
            y: imageSize.height - pixel.origin.y - pixel.size.height,
            width: pixel.size.width,
            height: pixel.size.height
        )
    }

    /// Inverse of `normalizedTopLeftToCIPixel`. Used when re-entering crop
    /// mode to seed the SwiftUI overlay from a stored Core Image rect.
    /// Degenerate (zero-sized) images return the input unchanged.
    public static func ciPixelToNormalizedTopLeft(rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let displayY = imageSize.height - rect.origin.y - rect.size.height
        return CGRect(
            x: rect.origin.x / imageSize.width,
            y: displayY / imageSize.height,
            width: rect.size.width / imageSize.width,
            height: rect.size.height / imageSize.height
        )
    }

    // MARK: - Aspect ratio

    /// Constrain `rect` to the given aspect `ratio` (width / height), keeping
    /// the corner at `anchor` fixed and resizing the opposite corner. When
    /// `ratio` is nil the rect is returned unchanged (free crop).
    ///
    /// `anchor` is expressed in the same space as `rect` (typically 0…1).
    /// The returned rect always has the exact requested ratio.
    public static func constrain(rect: CGRect, to ratio: Double?, anchor: CGPoint) -> CGRect {
        guard let ratio, ratio > 0 else { return rect }

        let currentW = abs(rect.width)
        let currentH = abs(rect.height)
        let targetW: CGFloat
        let targetH: CGFloat

        // Pick the dimension whose constraint is smaller so we never grow
        // past the current bounds in either axis. For a square anchor at
        // the top-left of a 0.6x0.3 rect, this keeps height=0.3 and
        // shrinks width to 0.3.
        if currentW / ratio <= currentH {
            targetH = currentW / CGFloat(ratio)
            targetW = currentW
        } else {
            targetW = currentH * CGFloat(ratio)
            targetH = currentH
        }

        let originX: CGFloat
        let originY: CGFloat
        if abs(anchor.x - rect.minX) < abs(anchor.x - rect.maxX) {
            // Anchor on the left side — grow right.
            originX = anchor.x
        } else {
            originX = anchor.x - targetW
        }
        if abs(anchor.y - rect.minY) < abs(anchor.y - rect.maxY) {
            originY = anchor.y
        } else {
            originY = anchor.y - targetH
        }
        return CGRect(x: originX, y: originY, width: targetW, height: targetH)
    }

    // MARK: - Angle

    /// Clamp a straighten angle to the supported range.
    public static func clampAngle(_ degrees: Double) -> Double {
        min(45.0, max(-45.0, degrees))
    }

    // MARK: - Rotated bounds

    /// Shrink `cropRect` (normalised 0…1) so that, when the underlying
    /// image is rotated by `angle` degrees around its centre, the crop
    /// still falls entirely within the rotated image content.
    ///
    /// At 0° the input is returned unchanged. At non-zero angles the
    /// crop is scaled toward its own centre by the largest factor that
    /// keeps both axes inside the rotated unit square.
    public static func fitCropToRotatedBounds(cropRect: CGRect, angle: Double) -> CGRect {
        if angle == 0 { return cropRect }
        let theta = abs(angle) * .pi / 180.0
        let cosT = Foundation.cos(theta)
        let sinT = Foundation.sin(theta)
        let w = cropRect.width
        let h = cropRect.height
        guard w > 0, h > 0 else { return cropRect }

        // Both corners of the crop must lie within the rotated unit
        // square — the two constraints are:
        //   w·cos + h·sin ≤ 1   (projects onto the rotated x-axis)
        //   w·sin + h·cos ≤ 1   (projects onto the rotated y-axis)
        let limitX = 1.0 / (w * cosT + h * sinT)
        let limitY = 1.0 / (w * sinT + h * cosT)
        let k = min(1.0, min(limitX, limitY))
        let newW = w * k
        let newH = h * k
        let cx = cropRect.midX
        let cy = cropRect.midY
        return CGRect(
            x: cx - newW / 2,
            y: cy - newH / 2,
            width: newW,
            height: newH
        )
    }
}
