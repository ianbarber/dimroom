import CoreImage
import Catalog

/// Stateless Core Image filter graph renderer.
///
/// Applies an `EditState` to a source `CIImage` by chaining nine filter stages
/// in a fixed order. Each stage is a no-op when its parameter is at identity.
/// The caller owns the `CIContext` — this renderer only builds the filter graph.
public enum Renderer {

    /// Apply all edits described by `editState` to `source` and return the result.
    public static func render(source: CIImage, editState: EditState) -> CIImage {
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

        let gradient = CIFilter(name: "CIRadialGradient")!
        gradient.setValue(center, forKey: "inputCenter")
        gradient.setValue(innerRadius, forKey: "inputRadius0")
        gradient.setValue(outerRadius, forKey: "inputRadius1")
        // Mask: inner is black (no effect), outer is white (full effect).
        gradient.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor0")
        gradient.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")
        let mask = gradient.outputImage!.cropped(to: extent)

        // Blend the image with a tint image (black for dark, white for light)
        // using the radial mask — corners converge toward the tint colour.
        let intensity = Swift.abs(amount) / 100.0
        let tintColor: CIColor = amount < 0
            ? CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(intensity))
            : CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(intensity))
        let tint = CIImage(color: tintColor).cropped(to: extent)

        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(tint, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: "inputMaskImage")
        return blend.outputImage!.cropped(to: extent)
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
