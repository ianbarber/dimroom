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
        image = applyWhiteBalance(image, temperature: editState.temperature, tint: editState.tint)
        image = applyHighlightsShadows(image, highlights: editState.highlights, shadows: editState.shadows)
        image = applyWhitesBlacks(image, whites: editState.whites, blacks: editState.blacks)
        image = applyContrast(image, contrast: editState.contrast)
        image = applyClarity(image, clarity: editState.clarity)
        image = applyVibrance(image, vibrance: editState.vibrance)
        image = applySaturation(image, saturation: editState.saturation)
        image = applyCrop(image, rect: editState.cropRect, angle: editState.cropAngle)
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
        // CIHighlightShadowAdjust: highlightAmount default is 1.0 (no change);
        // values < 1 recover highlights, > 1 brightens them.
        // shadowAmount default is 0.0 (no change); positive lifts shadows.
        filter.setValue(1.0 + highlights / 100.0, forKey: "inputHighlightAmount")
        filter.setValue(shadows / 100.0, forKey: "inputShadowAmount")
        return filter.outputImage!
    }

    private static func applyWhitesBlacks(_ image: CIImage, whites: Double, blacks: Double) -> CIImage {
        guard whites != 0 || blacks != 0 else { return image }
        let filter = CIFilter(name: "CIToneCurve")!
        filter.setValue(image, forKey: kCIInputImageKey)
        // Five-point tone curve. Identity is a straight line from (0,0) to (1,1).
        // Whites adjust the top endpoint, blacks adjust the bottom endpoint.
        let blacksY = max(0.0, min(1.0, blacks / 200.0))
        let whitesY = max(0.0, min(1.0, 1.0 + whites / 200.0))
        filter.setValue(CIVector(x: 0.0, y: CGFloat(blacksY)), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: 0.25), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: 0.75), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1.0, y: CGFloat(whitesY)), forKey: "inputPoint4")
        return filter.outputImage!
    }

    private static func applyContrast(_ image: CIImage, contrast: Double) -> CIImage {
        guard contrast != 0 else { return image }
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.0 + contrast / 100.0, forKey: "inputContrast")
        filter.setValue(1.0, forKey: "inputSaturation")
        filter.setValue(0.0, forKey: "inputBrightness")
        return filter.outputImage!
    }

    private static func applyClarity(_ image: CIImage, clarity: Double) -> CIImage {
        guard clarity != 0 else { return image }

        if clarity > 0 {
            // Positive: large-radius unsharp mask for local contrast enhancement.
            let filter = CIFilter(name: "CIUnsharpMask")!
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(20.0, forKey: "inputRadius")
            filter.setValue(clarity / 100.0, forKey: "inputIntensity")
            return filter.outputImage!
        } else {
            // Negative: blend toward a Gaussian blur for softening/diffusion.
            let blendFraction = Swift.abs(clarity) / 100.0

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
        filter.setValue(1.0 + saturation / 100.0, forKey: "inputSaturation")
        filter.setValue(1.0, forKey: "inputContrast")
        filter.setValue(0.0, forKey: "inputBrightness")
        return filter.outputImage!
    }

    private static func applyCrop(_ image: CIImage, rect: CGRect?, angle: Double?) -> CIImage {
        guard let cropRect = rect else { return image }
        var result = image

        // Apply rotation around image center if angle is set
        if let angle = angle, angle != 0 {
            let radians = angle * .pi / 180.0
            let cx = result.extent.midX
            let cy = result.extent.midY
            let transform = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: CGFloat(radians))
                .translatedBy(x: -cx, y: -cy)
            result = result.transformed(by: transform)
        }

        result = result.cropped(to: cropRect)
        // Translate so the crop origin is at (0,0)
        result = result.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        return result
    }
}
