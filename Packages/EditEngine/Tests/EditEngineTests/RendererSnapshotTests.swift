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

    func testLightVignetteSnapshot() {
        let source = makeMidGreyImage()
        let image = renderToNSImage(
            source: source,
            editState: EditState(vignetteAmount: 80, vignetteRoundness: 50, vignetteSoftness: 50)
        )
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }
}
