import CoreImage
import Catalog

/// Stateless Core Image filter graph renderer.
///
/// Applies an `EditState` to a source `CIImage` by chaining filter stages in a
/// fixed order. Each stage is a no-op when its parameter is at identity. The
/// caller owns the `CIContext` — this renderer only builds the filter graph.
///
/// Pipeline order:
///   1. Tone / colour: exposure, noise reduction, white balance, highlights+shadows,
///      whites+blacks, contrast, clarity, sharpening, vibrance, saturation.
///   2. Geometric / lens stage: chromatic aberration correction, perspective +
///      fine rotation, lens-vignette correction, crop.
///   3. Creative vignette (applied after crop so the vignette tracks the
///      final framing rather than the uncropped sensor frame).
public enum Renderer {

    /// Apply all edits described by `editState` to `source` and return the result.
    ///
    /// `lensProfile` drives the chromatic-aberration and lens-vignette
    /// correction magnitudes when those flags are enabled. Pass `nil` (the
    /// default) to fall back to the conservative built-in placeholder used
    /// when no profile is registered for the asset's lens model. Resolving
    /// the profile is the caller's job — the renderer stays Asset-agnostic.
    public static func render(
        source: CIImage,
        editState: EditState,
        lensProfile: LensProfile? = nil
    ) -> CIImage {
        var image = source
        image = applyExposure(image, ev: editState.exposure)
        image = applyNoiseReduction(
            image,
            luminance: editState.luminanceNoiseReduction,
            chrominance: editState.chrominanceNoiseReduction
        )
        image = applyWhiteBalance(image, temperature: editState.temperature, tint: editState.tint)
        image = applyHighlightsShadows(image, highlights: editState.highlights, shadows: editState.shadows)
        image = applyWhitesBlacks(image, whites: editState.whites, blacks: editState.blacks)
        image = applyContrast(image, contrast: editState.contrast)
        image = applyToneCurves(
            image,
            luminance: editState.toneCurvePoints,
            red: editState.redCurvePoints,
            green: editState.greenCurvePoints,
            blue: editState.blueCurvePoints
        )
        image = applyClarity(image, clarity: editState.clarity)
        image = applySharpening(image, sharpening: editState.sharpening)
        image = applyVibrance(image, vibrance: editState.vibrance)
        image = applySaturation(image, saturation: editState.saturation)
        image = applyHSL(
            image,
            hueShift: editState.hueShift,
            saturation: editState.hslSaturation,
            luminance: editState.hslLuminance
        )
        image = applySplitTone(
            image,
            highlightHue: editState.splitToneHighlightHue,
            highlightSaturation: editState.splitToneHighlightSaturation,
            shadowHue: editState.splitToneShadowHue,
            shadowSaturation: editState.splitToneShadowSaturation,
            balance: editState.splitToneBalance
        )
        image = applyChromaticAberrationCorrection(
            image,
            enabled: editState.chromaticAberration,
            profile: lensProfile
        )
        image = applyGeometryCorrections(
            image,
            vertical: editState.perspectiveVertical,
            horizontal: editState.perspectiveHorizontal,
            rotation: editState.perspectiveRotation
        )
        image = applyLensVignetteCorrection(
            image,
            enabled: editState.lensVignette,
            profile: lensProfile
        )
        image = applyCrop(image, rect: editState.cropRect, angle: editState.cropAngle)
        image = applyVignette(
            image,
            amount: editState.vignetteAmount,
            roundness: editState.vignetteRoundness,
            softness: editState.vignetteSoftness
        )
        return image
    }

    // MARK: - Filter stages

    private static func applyExposure(_ image: CIImage, ev: Double) -> CIImage {
        guard ev != 0 else { return image }
        let filter = CIFilter(name: "CIExposureAdjust")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(ev, forKey: "inputEV")
        return filter.outputImage!
    }

    private static func applyWhiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard temperature != 6500 || tint != 0 else { return image }
        let filter = CIFilter(name: "CITemperatureAndTint")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: CGFloat(temperature), y: CGFloat(tint)), forKey: "inputTargetNeutral")
        return filter.outputImage!
    }

    private static func applyHighlightsShadows(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return image }
        let filter = CIFilter(name: "CIHighlightShadowAdjust")!
        filter.setValue(image, forKey: kCIInputImageKey)
        // CIHighlightShadowAdjust: highlightAmount default 1.0, shadowAmount default 0.
        // Halve the slider-to-input scale so ±100 lands at 1.0±0.5 / ±0.5 rather than
        // the filter's raw 0…2 / -1…1 range, where the extremes clip hard.
        filter.setValue(1.0 + highlights / 200.0, forKey: "inputHighlightAmount")
        filter.setValue(shadows / 200.0, forKey: "inputShadowAmount")
        return filter.outputImage!
    }

    private static func applyWhitesBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage {
        guard whites != 0 || blacks != 0 else { return image }
        let filter = CIFilter(name: "CIToneCurve")!
        filter.setValue(image, forKey: kCIInputImageKey)
        // Five-point tone curve with locked (0,0) and (1,1) endpoints so pure
        // black and pure white pass through unchanged. Blacks drives the 0.25
        // interior point, whites drives the 0.75 interior point — ±100 shifts
        // each by ±0.2, keeping y values inside [0.05, 0.45] and [0.55, 0.95]
        // so the curve stays monotonic and both slider directions have
        // usable range. Earlier versions put whites/blacks on the endpoints,
        // which meant +100 whites / -100 blacks clamped to identity (#155).
        let blacksY = 0.25 + blacks / 500.0
        let whitesY = 0.75 + whites / 500.0
        filter.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: CGFloat(blacksY)), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: CGFloat(whitesY)), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
        return filter.outputImage!
    }

    private static func applyContrast(_ image: CIImage, contrast: Double) -> CIImage {
        guard contrast != 0 else { return image }
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(image, forKey: kCIInputImageKey)
        // Map ±100 to 0.5…1.5 instead of 0…2. At 2.0 CIColorControls crushes blacks
        // / blows highlights so hard most of the upper slider travel is unusable.
        filter.setValue(1.0 + contrast / 200.0, forKey: "inputContrast")
        filter.setValue(1.0, forKey: "inputSaturation")
        filter.setValue(0.0, forKey: "inputBrightness")
        return filter.outputImage!
    }

    private static func applyClarity(_ image: CIImage, clarity: Double) -> CIImage {
        guard clarity != 0 else { return image }

        // Cap both sides at 0.5 of the underlying filter range — full intensity
        // produced ringing (positive) or excessive blur (negative) long before
        // the slider reached ±100.
        if clarity > 0 {
            // Positive: large-radius unsharp mask for local contrast enhancement.
            let filter = CIFilter(name: "CIUnsharpMask")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(20.0, forKey: "inputRadius")
            filter.setValue(clarity / 200.0, forKey: "inputIntensity")
            return filter.outputImage!
        } else {
            // Negative: blend toward a Gaussian blur for softening/diffusion.
            let blendFraction = Swift.abs(clarity) / 200.0

            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(image, forKey: kCIInputImageKey)
            blur.setValue(20.0, forKey: "inputRadius")
            let blurred = blur.outputImage!.cropped(to: image.extent)

            // Lerp: result = source * (1 - t) + blurred * t
            let sourceScaled = applyScale(image, factor: 1.0 - blendFraction)
            let blurredScaled = applyScale(blurred, factor: blendFraction)

            let add = CIFilter(name: "CIAdditionCompositing")!
            add.setValue(sourceScaled, forKey: kCIInputImageKey)
            add.setValue(blurredScaled, forKey: kCIInputBackgroundImageKey)
            return add.outputImage!
        }
    }

    /// Scale all channels of an image by a constant factor using CIColorMatrix.
    private static func applyScale(_ image: CIImage, factor: Double) -> CIImage {
        let f = CGFloat(factor)
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: f, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: f, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: f, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return filter.outputImage!
    }

    private static func applyVibrance(_ image: CIImage, vibrance: Double) -> CIImage {
        guard vibrance != 0 else { return image }
        let filter = CIFilter(name: "CIVibrance")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(vibrance / 100.0, forKey: "inputAmount")
        return filter.outputImage!
    }

    private static func applySaturation(_ image: CIImage, saturation: Double) -> CIImage {
        guard saturation != 0 else { return image }
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(image, forKey: kCIInputImageKey)
        // Asymmetric: -100 → 0 (fully desaturated, a useful endpoint), +100 → 1.5
        // (a strong boost well short of the filter's 2× limit, which wraps hue).
        let input = saturation >= 0 ? 1.0 + saturation / 200.0 : 1.0 + saturation / 100.0
        filter.setValue(input, forKey: "inputSaturation")
        filter.setValue(1.0, forKey: "inputContrast")
        filter.setValue(0.0, forKey: "inputBrightness")
        return filter.outputImage!
    }

    private static func applyNoiseReduction(
        _ image: CIImage,
        luminance: Double,
        chrominance: Double
    ) -> CIImage {
        guard luminance != 0 || chrominance != 0 else { return image }
        // CINoiseReduction packs both luma and chroma NR into a single pass:
        // `inputNoiseLevel` is the chroma noise threshold (more aggressive
        // chroma denoising as it climbs), and `inputSharpness` is how much
        // luminance detail to keep afterward (lower = more luma smoothing).
        // Map chroma 0…100 → 0…0.1 and luma 0…100 → 0.9…0.4 (inverted) so
        // a slider at zero leaves that axis at the filter's near-identity
        // value while the other slider acts independently.
        let filter = CIFilter(name: "CINoiseReduction")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(chrominance / 1000.0, forKey: "inputNoiseLevel")
        filter.setValue(0.9 - (luminance / 100.0) * 0.5, forKey: "inputSharpness")
        return filter.outputImage!.cropped(to: image.extent)
    }

    private static func applySplitTone(
        _ image: CIImage,
        highlightHue: Double,
        highlightSaturation: Double,
        shadowHue: Double,
        shadowSaturation: Double,
        balance: Double
    ) -> CIImage {
        // Fast path: both saturations at 0 means no tint to add. Hue and
        // balance alone are no-ops in that case.
        guard highlightSaturation > 0 || shadowSaturation > 0 else { return image }
        guard let kernel = SplitToneKernel.kernel else { return image }

        let highlight = SplitToneKernel.hslToRGB(
            hue: highlightHue,
            saturation: highlightSaturation / 100.0
        )
        let shadow = SplitToneKernel.hslToRGB(
            hue: shadowHue,
            saturation: shadowSaturation / 100.0
        )

        let highlightVec = CIVector(
            x: CGFloat(highlight.0),
            y: CGFloat(highlight.1),
            z: CGFloat(highlight.2)
        )
        let shadowVec = CIVector(
            x: CGFloat(shadow.0),
            y: CGFloat(shadow.1),
            z: CGFloat(shadow.2)
        )
        let balanceArg = max(-1.0, min(1.0, balance / 100.0))

        let result = kernel.apply(
            extent: image.extent,
            arguments: [image, highlightVec, shadowVec, balanceArg]
        )
        return result ?? image
    }

    private static func applySharpening(_ image: CIImage, sharpening: Double) -> CIImage {
        guard sharpening != 0 else { return image }
        // Luminance-only sharpen avoids the colour fringing CIUnsharpMask can
        // introduce on saturated edges. Map 0…100 to 0…2.0 — the upper end is
        // a strong output sharpen without visible haloing on photo previews.
        let filter = CIFilter(name: "CISharpenLuminance")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(sharpening / 50.0, forKey: "inputSharpness")
        return filter.outputImage!.cropped(to: image.extent)
    }

    private static func applyVignette(
        _ image: CIImage,
        amount: Double,
        roundness: Double,
        softness: Double
    ) -> CIImage {
        guard amount != 0 else { return image }

        let extent = image.extent
        let center = CIVector(x: extent.midX, y: extent.midY)

        // Roundness maps to the radial gradient's inner/outer radii relative
        // to the image's shortest half-dimension. At roundness=100 the inner
        // radius is large and close to the outer radius — the gradient hugs
        // the corners as a circle. At roundness=0 the inner radius is small,
        // producing a broad gradient that reaches the frame edges roughly
        // following their rectangular shape.
        let halfMin = Double(min(extent.width, extent.height)) / 2.0
        let halfDiag = sqrt(Double(extent.width * extent.width + extent.height * extent.height)) / 2.0

        // Softness controls the distance between inner and outer radii.
        // softness=0 → hard edge (inner ≈ outer), softness=100 → gradient
        // spans the full shortest half-dimension.
        let softnessFraction = 0.15 + (softness / 100.0) * 0.85
        let roundnessFraction = roundness / 100.0

        // Outer radius extends further (past the corners) as roundness
        // decreases so rectangular frames get full edge coverage.
        let outerRadius = halfMin + (halfDiag - halfMin) * (1.0 - roundnessFraction)
        let innerRadius = max(0.0, outerRadius - halfMin * softnessFraction)

        // The mask itself encodes the effect strength: outer alpha rises
        // to `strength` (not 1) so the blend mixes only that fraction of
        // the opaque tint over the source. Putting the strength on the
        // mask (rather than the tint's alpha) keeps the output fully
        // opaque — the previous alpha-driven tint produced corners with
        // alpha < 1 that the Develop view's dark background showed
        // through, making any negative amount read as near-black (#240).
        //
        // `maxStrength` caps the effect so ±100 reads as "strong but
        // photographic" rather than crushing corners to pure black or
        // white. The linear amount→strength mapping then gives a
        // visible, monotonic gradient across the full slider range.
        let maxStrength = 0.75
        let strength = (Swift.abs(amount) / 100.0) * maxStrength

        let gradient = CIFilter(name: "CIRadialGradient")!
        gradient.setValue(center, forKey: "inputCenter")
        gradient.setValue(innerRadius, forKey: "inputRadius0")
        gradient.setValue(outerRadius, forKey: "inputRadius1")
        // Mask: inner is fully transparent (no effect), outer reaches
        // `strength` in both luminance and alpha so the blend factor at
        // the corner equals `strength`.
        gradient.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor0")
        gradient.setValue(
            CIColor(red: strength, green: strength, blue: strength, alpha: strength),
            forKey: "inputColor1"
        )
        let mask = gradient.outputImage!.cropped(to: extent)

        // Opaque tint — alpha=1 on both channels so the blended output
        // stays opaque regardless of the mask's strength.
        let tintColor: CIColor = amount < 0
            ? CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            : CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let tint = CIImage(color: tintColor).cropped(to: extent)

        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(tint, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: "inputMaskImage")
        return blend.outputImage!.cropped(to: extent)
    }

    /// Keystone correction + fine rotation via a single `CIPerspectiveTransform`.
    /// All three controls fold into one warped quad so we resample once.
    ///
    /// Slider mapping: ±100 vertical inset = ±25 % of image width applied to the
    /// top/bottom edges (positive vertical pulls the top edge inward to correct
    /// converging verticals shot looking up). Horizontal mirrors that on the left
    /// and right edges. Rotation is a corner rotation about the centre and is
    /// composed into the same quad — separate from `cropAngle`, which lives on
    /// the crop tool and is not destructive to perspective.
    ///
    /// `CIPerspectiveTransform` expands the extent to the bounding box of the
    /// warped corners; we `cropped(to:)` the original extent so downstream
    /// stages see a canonical extent. Same gotcha as `applySharpening`.
    private static func applyGeometryCorrections(
        _ image: CIImage,
        vertical: Double,
        horizontal: Double,
        rotation: Double
    ) -> CIImage {
        guard vertical != 0 || horizontal != 0 || rotation != 0 else { return image }

        let extent = image.extent
        let w = extent.width
        let h = extent.height
        let cx = extent.midX
        let cy = extent.midY

        // Vertical keystone: positive pulls the top edge inward (corrects
        // looking-up converging verticals). Negative pulls the bottom.
        // ±100 → ±25 % of width inset on the corresponding edge.
        let vFrac = vertical / 400.0
        let topInset = max(0.0, vFrac) * w
        let bottomInset = max(0.0, -vFrac) * w

        // Horizontal keystone: positive pulls the right edge inward (corrects
        // looking-right). Negative pulls the left edge.
        let hFrac = horizontal / 400.0
        let rightInset = max(0.0, hFrac) * h
        let leftInset = max(0.0, -hFrac) * h

        // Build the warped quad in image coordinates (origin bottom-left).
        var tl = CGPoint(x: extent.minX + topInset, y: extent.maxY - leftInset)
        var tr = CGPoint(x: extent.maxX - topInset, y: extent.maxY - rightInset)
        var bl = CGPoint(x: extent.minX + bottomInset, y: extent.minY + leftInset)
        var br = CGPoint(x: extent.maxX - bottomInset, y: extent.minY + rightInset)

        if rotation != 0 {
            let radians = rotation * .pi / 180.0
            let cosR = CGFloat(cos(radians))
            let sinR = CGFloat(sin(radians))
            func rotate(_ p: CGPoint) -> CGPoint {
                let dx = p.x - cx
                let dy = p.y - cy
                return CGPoint(x: cx + dx * cosR - dy * sinR, y: cy + dx * sinR + dy * cosR)
            }
            tl = rotate(tl); tr = rotate(tr); bl = rotate(bl); br = rotate(br)
        }

        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
        return filter.outputImage!.cropped(to: extent)
    }

    /// Auto-correct chromatic aberration via a uniform per-channel radial
    /// scale about the image centre. When `profile` is non-nil the per-channel
    /// scales come from the lens profile; otherwise we fall back to a
    /// conservative built-in placeholder (±0.5 %) tuned to nudge fringes on
    /// a typical fast-prime wide-open shot without visibly softening clean
    /// images. Callers resolve the profile via `LensProfileLibrary.lookup`.
    private static func applyChromaticAberrationCorrection(
        _ image: CIImage,
        enabled: Bool,
        profile: LensProfile?
    ) -> CIImage {
        guard enabled else { return image }

        // Lens-profile values override per-asset. Fallback defaults (±0.5 %)
        // are conservative — typical lateral CA on mid-range lenses is well
        // under 1 % on the worst channel — but small enough to be a no-op on
        // a clean image. Single-pass CIKernel does R/G/B in one sample so
        // alpha stays exact and G passes through bit-exact (#275).
        return ChromaticAberrationKernel.apply(
            image,
            rScale: profile?.caRedScale ?? 0.995,
            bScale: profile?.caBlueScale ?? 1.005
        )
    }

    /// Auto-correct natural lens vignetting (corner darkening) with an
    /// inverted brightening profile centred on the frame. Distinct from the
    /// creative `applyVignette` stage which intentionally darkens or lightens
    /// corners — this stage flattens the lens's intrinsic falloff so the
    /// creative vignette has a known starting point.
    ///
    /// When `profile` is non-nil the `CIVignette` parameters come from the
    /// lens profile; otherwise we fall back to a conservative built-in
    /// placeholder (intensity -0.15, radius 1.0) tuned to be near-no-op on a
    /// clean centre while still measurably brightening genuinely vignetted
    /// corners (#274).
    private static func applyLensVignetteCorrection(
        _ image: CIImage,
        enabled: Bool,
        profile: LensProfile?
    ) -> CIImage {
        guard enabled else { return image }
        let filter = CIFilter(name: "CIVignette")!
        filter.setValue(image, forKey: kCIInputImageKey)
        // Negative intensity inverts the vignette: corners brighten rather
        // than darken. Lens-profile values override per-asset.
        filter.setValue(profile?.vignetteIntensity ?? -0.15, forKey: "inputIntensity")
        filter.setValue(profile?.vignetteRadius ?? 1.0, forKey: "inputRadius")
        return filter.outputImage!.cropped(to: image.extent)
    }

    /// Apply per-band hue / saturation / luminance shifts via the
    /// `HSLKernel` custom Core Image color kernel. Fast-path returns the
    /// input unchanged when every per-band value across all three axes
    /// is zero — common in the identity / pre-HSL catalogs.
    private static func applyHSL(
        _ image: CIImage,
        hueShift: [Double],
        saturation: [Double],
        luminance: [Double]
    ) -> CIImage {
        let allZero = hueShift.allSatisfy { $0 == 0 }
            && saturation.allSatisfy { $0 == 0 }
            && luminance.allSatisfy { $0 == 0 }
        guard !allZero else { return image }
        return HSLKernel.apply(
            image,
            hueShift: hueShift,
            saturation: saturation,
            luminance: luminance
        )
    }

    /// Apply luminance + per-channel curves as a single composed 256-entry
    /// LUT through `CIColorCurves`. Composition order: luminance first, then
    /// per-channel — `output_c = perChannel_c(luminance(input_c))` for each
    /// of R, G, B. "Luminance" here is the same curve applied to each
    /// channel independently (matches Lightroom's RGB curve, not a true
    /// luminance space transform). Identity-skips when all four curves
    /// equal `[(0,0), (1,1)]`.
    private static func applyToneCurves(
        _ image: CIImage,
        luminance: [CGPoint],
        red: [CGPoint],
        green: [CGPoint],
        blue: [CGPoint]
    ) -> CIImage {
        if isIdentityCurve(luminance)
            && isIdentityCurve(red)
            && isIdentityCurve(green)
            && isIdentityCurve(blue) {
            return image
        }

        let count = 256
        var data = Data(count: count * 3 * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?
                .bindMemory(to: Float.self, capacity: count * 3) else { return }
            for i in 0..<count {
                let t = Double(i) / Double(count - 1)
                let lumOut = evaluatePiecewiseLinear(curve: luminance, at: t)
                let rOut = evaluatePiecewiseLinear(curve: red, at: lumOut)
                let gOut = evaluatePiecewiseLinear(curve: green, at: lumOut)
                let bOut = evaluatePiecewiseLinear(curve: blue, at: lumOut)
                base[i * 3]     = Float(clamp01(rOut))
                base[i * 3 + 1] = Float(clamp01(gOut))
                base[i * 3 + 2] = Float(clamp01(bOut))
            }
        }

        let filter = CIFilter(name: "CIColorCurves")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(data as NSData, forKey: "inputCurvesData")
        filter.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
        return filter.outputImage!.cropped(to: image.extent)
    }

    /// Sample a piecewise-linear curve at `x`. Endpoints clamp to the
    /// curve's first and last y values. Assumes points are sorted by x.
    private static func evaluatePiecewiseLinear(curve: [CGPoint], at x: Double) -> Double {
        guard !curve.isEmpty else { return x }
        if curve.count == 1 { return Double(curve[0].y) }
        let xv = CGFloat(x)
        if xv <= curve[0].x { return Double(curve[0].y) }
        if xv >= curve[curve.count - 1].x { return Double(curve[curve.count - 1].y) }
        for i in 0..<(curve.count - 1) {
            let p0 = curve[i]
            let p1 = curve[i + 1]
            if xv >= p0.x && xv <= p1.x {
                let span = p1.x - p0.x
                if span <= 0 { return Double(p0.y) }
                let t = (xv - p0.x) / span
                return Double(p0.y + (p1.y - p0.y) * t)
            }
        }
        return Double(curve[curve.count - 1].y)
    }

    /// Identity check used by `applyToneCurves` and exposed for callers
    /// that want to mirror the same "is this a no-op?" decision.
    static func isIdentityCurve(_ points: [CGPoint]) -> Bool {
        return points == EditState.identityCurve
    }

    private static func clamp01(_ v: Double) -> Double {
        if v < 0 { return 0 }
        if v > 1 { return 1 }
        return v
    }

    private static func applyCrop(_ image: CIImage, rect: CGRect?, angle: Double?) -> CIImage {
        var result = image

        if let angle, angle != 0 {
            let radians = angle * .pi / 180.0
            let cx = result.extent.midX
            let cy = result.extent.midY
            let transform = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: CGFloat(radians))
                .translatedBy(x: -cx, y: -cy)
            result = result.transformed(by: transform)
        }

        if let cropRect = rect {
            result = result.cropped(to: cropRect)
            result = result.transformed(by: CGAffineTransform(
                translationX: -cropRect.origin.x,
                y: -cropRect.origin.y
            ))
        }
        return result
    }
}
