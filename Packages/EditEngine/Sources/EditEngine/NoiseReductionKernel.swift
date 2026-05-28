import CoreImage

/// Recombines an image with a blurred copy of itself, blending the luma and
/// chroma axes independently so the two noise-reduction sliders never bleed
/// into each other.
///
/// Both inputs are converted to Rec.601 Y / Cb / Cr (the same luma and B−R
/// proxies the renderer tests score), the Y channel is blended by `lumaBlend`
/// and the Cb/Cr pair by `chromaBlend`, then reconstructed to RGB. The
/// reconstruction is built so the untouched axis is bit-stable: blending only
/// Y shifts R, G and B by the same amount, leaving B−R fixed; blending only
/// Cb/Cr keeps the reconstructed Y exact, leaving luma fixed. A slider at zero
/// is therefore a true no-op on the other axis.
///
/// Structure mirrors `SplitToneKernel` — inline CIKL source compiled once, with
/// a defensive `nil` fallback if the source ever fails to compile.
enum NoiseReductionKernel {

    /// Compiled `CIColorKernel`. `nil` only if the inline source fails to
    /// compile (a bug in the source string).
    static let kernel: CIColorKernel? = CIColorKernel(source: source)

    private static let source = """
    kernel vec4 dimroomNoiseReduction(__sample orig, __sample blurred, float lumaBlend, float chromaBlend) {
        vec3 o = orig.rgb;
        vec3 b = blurred.rgb;
        vec3 w = vec3(0.299, 0.587, 0.114);
        // Rec.601 luma + (R-Y, B-Y) chroma differences for both inputs.
        float yO = dot(o, w);
        float yB = dot(b, w);
        float crO = o.r - yO;
        float cbO = o.b - yO;
        float crB = b.r - yB;
        float cbB = b.b - yB;
        // Blend each axis toward the blurred copy independently.
        float y  = mix(yO, yB, lumaBlend);
        float cr = mix(crO, crB, chromaBlend);
        float cb = mix(cbO, cbB, chromaBlend);
        // Reconstruct RGB. By construction dot(rgb, w) == y exactly and
        // (b - r) == cb - cr, so each axis is independent of the other.
        float r = y + cr;
        float bch = y + cb;
        float g = y - (0.299 * cr + 0.114 * cb) / 0.587;
        return vec4(r, g, bch, orig.a);
    }
    """
}
