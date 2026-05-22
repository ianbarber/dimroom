import CoreImage
import Foundation

/// Single-pass chromatic-aberration correction. Samples the source at three
/// radially-scaled coordinates (one per RGB channel) and emits the per-channel
/// result with the source's alpha in one pass.
///
/// Replaces the previous three-image `CIAdditionCompositing` pipeline, which
/// relied on Core Image clamping `alpha = 3` back down to 1 after summing
/// channel-isolated images. That worked only for opaque inputs and made the
/// alpha semantics fragile. The kernel here passes alpha through untouched and
/// gives the G channel a bit-exact path (it samples at the unmodified
/// destination coordinate).
///
/// Uses `CIKernel` rather than `CIColorKernel` because the three channel
/// samples come from different source coordinates. Structure mirrors
/// `HSLKernel` — inline CIKL source, compiled once, defensive fallback to the
/// input image if compilation ever fails.
enum ChromaticAberrationKernel {

    /// Compiled-once kernel instance. `nil` only if the inline CIKL source
    /// fails to compile (a bug in the source string).
    static let kernel: CIKernel? = CIKernel(source: source)

    /// Apply the per-channel radial scale about the centre of `image.extent`.
    /// `rScale` < 1 shrinks the red channel toward the centre; `bScale` > 1
    /// expands the blue channel outward. Identity is `rScale = bScale = 1`.
    static func apply(_ image: CIImage, rScale: Double, bScale: Double) -> CIImage {
        guard let kernel else { return image }
        let extent = image.extent
        let center = CIVector(x: extent.midX, y: extent.midY)
        let arguments: [Any] = [
            image,
            center,
            NSNumber(value: rScale),
            NSNumber(value: bScale),
        ]
        // General CIKernel requires an explicit ROI callback. The radial scale
        // factors are within ~0.5 % of identity, so returning the full extent
        // is both safe and effectively free — the kernel only ever samples
        // within the source image, and edge pixels outside the extent return
        // transparent black just as the previous transformed+cropped pipeline
        // did.
        let roiCallback: CIKernelROICallback = { _, _ in extent }
        guard let output = kernel.apply(
            extent: extent,
            roiCallback: roiCallback,
            arguments: arguments
        ) else {
            return image
        }
        return output.cropped(to: extent)
    }

    /// CI Kernel Language source. Uses `samplerCoord(src)` for the green
    /// branch so that channel passes through bit-exact — `samplerTransform`
    /// composes an extra coordinate transform that can introduce sub-LSB
    /// drift, which would defeat the point of giving G an exact path.
    private static let source: String = """
    kernel vec4 dimroomChromaticAberration(sampler src, vec2 center, float rScale, float bScale) {
        vec2 d = destCoord();
        vec2 rPos = center + (d - center) / rScale;
        vec2 bPos = center + (d - center) / bScale;
        vec4 r = sample(src, samplerTransform(src, rPos));
        vec4 g = sample(src, samplerCoord(src));
        vec4 b = sample(src, samplerTransform(src, bPos));
        return vec4(r.r, g.g, b.b, g.a);
    }
    """
}
