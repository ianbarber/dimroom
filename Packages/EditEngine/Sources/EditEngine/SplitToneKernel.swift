import CoreImage

/// Custom Core Image colour kernel that applies a split-toning effect:
/// blend a "highlight tint" colour into bright pixels and a "shadow tint"
/// colour into dark pixels, with a balance parameter that shifts the
/// luminance midpoint where the two regions meet.
///
/// `balance` is the *normalised* form (-1…1, not the slider's -100…100)
/// — the Renderer scales the slider before calling.
enum SplitToneKernel {
    /// Compiled `CIColorKernel`, lazily built from the inline source.
    /// `nil` if the kernel source ever fails to compile (the renderer
    /// then falls back to a pass-through).
    static let kernel: CIColorKernel? = CIColorKernel(source: source)

    private static let source = """
    kernel vec4 splitTone(__sample s, vec3 highlightTint, vec3 shadowTint, float balance) {
        // Rec. 709 luminance — matches CIColorControls' notion of brightness.
        float lum = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
        // `balance` shifts the smoothstep's midpoint around 0.5. balance = -1
        // pushes the boundary toward black so almost everything reads as
        // "highlight"; +1 pushes it toward white so almost everything reads
        // as "shadow".
        float lo = clamp(0.5 + balance * 0.5 - 0.25, 0.0, 1.0);
        float hi = clamp(0.5 + balance * 0.5 + 0.25, 0.0, 1.0);
        float hw = smoothstep(lo, hi, lum);
        float sw = 1.0 - hw;
        vec3 rgb = s.rgb + highlightTint * hw + shadowTint * sw;
        rgb = clamp(rgb, 0.0, 1.0);
        return vec4(rgb, s.a);
    }
    """

    /// Convert HSL hue + saturation (with lightness pinned at 0.5) to an
    /// RGB triple. Used by the renderer to feed `vec3` tint colours into
    /// the kernel.
    ///
    /// - Parameters:
    ///   - hue: 0…360 degrees.
    ///   - saturation: 0…1.
    /// - Returns: linear RGB triple in 0…1 range. With saturation == 0
    ///   the result is (0, 0, 0) so the kernel's additive blend collapses
    ///   to identity.
    static func hslToRGB(hue: Double, saturation: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (0, 0, 0) }
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60.0
        let c = saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch h {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default:    (r, g, b) = (c, 0, x)
        }
        return (r, g, b)
    }
}
