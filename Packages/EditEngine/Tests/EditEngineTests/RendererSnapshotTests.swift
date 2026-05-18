import XCTest
import CoreImage
import Catalog
import TestSupport
@testable import EditEngine

final class RendererSnapshotTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    private func renderToNSImage(source: CIImage, editState: EditState) -> NSImage {
        let result = Renderer.render(source: source, editState: editState)
        let cgImage = ctx.createCGImage(result, from: result.extent)!
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func testIdentitySnapshot() {
        let source = makeGradientImage()
        let image = renderToNSImage(source: source, editState: EditState())
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testExposurePlusOneSnapshot() {
        let source = makeGradientImage()
        let image = renderToNSImage(source: source, editState: EditState(exposure: 1))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testWarmWhiteBalanceSnapshot() {
        let source = makeGradientImage()
        let image = renderToNSImage(source: source, editState: EditState(temperature: 5200))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testHeavyContrastSnapshot() {
        let source = makeGradientImage()
        let image = renderToNSImage(source: source, editState: EditState(contrast: 50))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testContrastMaxSnapshot() {
        // Locks the +100 ceiling introduced by the range remap. Regressing to
        // the old 0…2 mapping would visibly crush/blow this gradient and fail
        // the snapshot.
        let source = makeGradientImage()
        let image = renderToNSImage(source: source, editState: EditState(contrast: 100))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSaturationMaxSnapshot() {
        let source = makeColorImage()
        let image = renderToNSImage(source: source, editState: EditState(saturation: 100))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testCroppedSnapshot() {
        let source = makeGradientImage()
        let cropRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        let image = renderToNSImage(source: source, editState: EditState(cropRect: cropRect))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testNegativeClaritySnapshot() {
        let source = makeColorImage()
        let image = renderToNSImage(source: source, editState: EditState(clarity: -60))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testCroppedWithRotationSnapshot() {
        let source = makeGradientImage()
        let cropRect = CGRect(x: 8, y: 8, width: 48, height: 48)
        let image = renderToNSImage(
            source: source,
            editState: EditState(cropRect: cropRect, cropAngle: 5)
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSharpeningSnapshot() {
        let source = makeColorImage()
        let image = renderToNSImage(source: source, editState: EditState(sharpening: 80))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testDarkVignetteSnapshot() {
        let source = makeMidGreyImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(vignetteAmount: -80, vignetteRoundness: 50, vignetteSoftness: 50)
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testStrongNoiseReductionSnapshot() {
        let source = makeColorImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(luminanceNoiseReduction: 80, chrominanceNoiseReduction: 80)
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSplitToneOrangeTealSnapshot() {
        // Classic orange-highlights / teal-shadows colour grade applied
        // over a black-to-white gradient — both ends pick up their
        // respective tint while the centre region transitions through
        // the smoothstep boundary.
        let source = makeGradientImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(
                splitToneHighlightHue: 30,
                splitToneHighlightSaturation: 60,
                splitToneShadowHue: 195,
                splitToneShadowSaturation: 60
            )
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testSplitToneBalanceShiftSnapshot() {
        // Same orange/teal tints, but with balance pushed +50 toward the
        // shadows — the cool tint now reaches further into the midtones.
        let source = makeGradientImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(
                splitToneHighlightHue: 30,
                splitToneHighlightSaturation: 60,
                splitToneShadowHue: 195,
                splitToneShadowSaturation: 60,
                splitToneBalance: 50
            )
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testLightVignetteSnapshot() {
        let source = makeMidGreyImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(vignetteAmount: 80, vignetteRoundness: 50, vignetteSoftness: 50)
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testHSLHueShiftRedSnapshot() {
        let source = makeColorImage()
        var hue = EditState.hslIdentity
        hue[0] = 80
        let image = renderToNSImage(source: source, editState: EditState(hueShift: hue))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testHSLSaturationGreenSnapshot() {
        // Source must contain green pixels for the green-band saturation to
        // produce a visible effect; `makeColorImage` (red + blue) leaves the
        // snapshot indistinguishable from identity. A pure-green sample
        // exercises the band's actual desaturation.
        let source = makeSolidColorImage(r: 30, g: 200, b: 30)
        var sat = EditState.hslIdentity
        sat[3] = -80 // Green band
        let image = renderToNSImage(source: source, editState: EditState(hslSaturation: sat))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testHSLLuminanceBlueSnapshot() {
        let source = makeColorImage()
        var lum = EditState.hslIdentity
        lum[5] = -60 // Blue band
        let image = renderToNSImage(source: source, editState: EditState(hslLuminance: lum))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }

    func testLuminanceSCurveSnapshot() {
        // Lock the visual output of a non-trivial luminance curve so a
        // future LUT-composition or interpolation change is caught.
        let sCurve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.10),
            CGPoint(x: 0.75, y: 0.90),
            CGPoint(x: 1, y: 1)
        ]
        let source = makeGradientImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(toneCurvePoints: sCurve)
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }
}
