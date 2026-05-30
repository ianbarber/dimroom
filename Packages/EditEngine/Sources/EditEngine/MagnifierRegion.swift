import CoreGraphics

/// Pure geometry for the Develop pixel magnifier (#324).
///
/// Given an image's pixel size, a normalised sample centre, and the
/// number of pixels the magnifier should cover, computes the source
/// pixel rect to crop out. The rect never extends past the image edges:
/// near a border the centre is re-anchored inward so the returned rect is
/// always fully inside the image. For an image smaller than the requested
/// region in a dimension, that dimension is clamped to the full image.
///
/// No Core Image — directly Layer-A testable.
public enum MagnifierRegion {

    /// Compute the clamped pixel rect to sample from an image of
    /// `imageSize` (pixels), centred on `sampleCenter` (normalised
    /// `0…1`, **top-left origin** — matching the on-screen coordinates
    /// the reticle is dragged in), covering `regionSize` pixels.
    ///
    /// Returns a rect in **Core Image pixel coordinates** (bottom-left
    /// origin) suitable for passing straight to `CIContext.createCGImage`.
    ///
    /// - The returned size never exceeds `imageSize` in either axis.
    /// - The returned origin keeps the rect fully inside `[0, imageSize]`.
    public static func clampedSourceRect(
        imageSize: CGSize,
        sampleCenter: CGPoint,
        regionSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }

        let regionW = min(max(regionSize.width, 0), imageSize.width)
        let regionH = min(max(regionSize.height, 0), imageSize.height)

        let nx = clamp01(sampleCenter.x)
        let ny = clamp01(sampleCenter.y)

        // Sample centre in Core Image pixel space (origin bottom-left).
        // The horizontal axis matches; the vertical axis is flipped
        // because `sampleCenter` uses a top-left origin.
        let centerX = nx * imageSize.width
        let centerY = (1 - ny) * imageSize.height

        let originX = clamp(centerX - regionW / 2, lower: 0, upper: imageSize.width - regionW)
        let originY = clamp(centerY - regionH / 2, lower: 0, upper: imageSize.height - regionH)

        return CGRect(x: originX, y: originY, width: regionW, height: regionH)
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat {
        clamp(v, lower: 0, upper: 1)
    }

    private static func clamp(_ v: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if upper < lower { return lower }
        if v < lower { return lower }
        if v > upper { return upper }
        return v
    }
}
