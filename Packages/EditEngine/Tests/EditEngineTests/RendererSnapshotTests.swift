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

    func testCroppedSnapshot() {
        let source = makeGradientImage()
        let cropRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        let image = renderToNSImage(source: source, editState: EditState(cropRect: cropRect))
        assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98))
    }
}
