import XCTest
import CoreImage
import Catalog
@testable import EditEngine

final class RendererTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    // MARK: - Identity

    func testIdentityPassThrough() {
        let source = makeGradientImage()
        let result = Renderer.render(source: source, editState: EditState())

        // Extent must be unchanged
        XCTAssertEqual(result.extent, source.extent)

        // Sample centre pixel — should be identical within tolerance
        let mid = Int(source.extent.width) / 2
        let srcPx = samplePixel(image: source, x: mid, y: mid, context: ctx)
        let resPx = samplePixel(image: result, x: mid, y: mid, context: ctx)
        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
        XCTAssertEqual(srcPx.a, resPx.a)
    }

    // MARK: - Exposure

    func testExposureShiftsPixels() {
        let source = makeGradientImage()
        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2
        let srcPx = samplePixel(image: source, x: midX, y: midY, context: ctx)

        // +1 EV should brighten
        let bright = Renderer.render(source: source, editState: EditState(exposure: 1))
        let brightPx = samplePixel(image: bright, x: midX, y: midY, context: ctx)
        XCTAssertGreaterThan(brightPx.r, srcPx.r, "Positive exposure should brighten")

        // -1 EV should darken
        let dark = Renderer.render(source: source, editState: EditState(exposure: -1))
        let darkPx = samplePixel(image: dark, x: midX, y: midY, context: ctx)
        XCTAssertLessThan(darkPx.r, srcPx.r, "Negative exposure should darken")
    }

    // MARK: - Contrast

    func testContrastChangesMidtones() {
        let source = makeGradientImage()
        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2

        // High contrast should push midtones away from 0.5
        let result = Renderer.render(source: source, editState: EditState(contrast: 50))
        let srcPx = samplePixel(image: source, x: midX, y: midY, context: ctx)
        let resPx = samplePixel(image: result, x: midX, y: midY, context: ctx)

        // The midtone pixel should differ from the source midtone
        XCTAssertNotEqual(srcPx.r, resPx.r, "Contrast should change midtone values")
    }

    // MARK: - White balance

    func testWhiteBalanceShifts() {
        let source = makeGradientImage()
        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2
        let srcPx = samplePixel(image: source, x: midX, y: midY, context: ctx)

        // Warm (lower temp) should shift the colour
        let warm = Renderer.render(source: source, editState: EditState(temperature: 4000))
        let warmPx = samplePixel(image: warm, x: midX, y: midY, context: ctx)

        // At least one channel should differ
        let channelsDiffer = srcPx.r != warmPx.r || srcPx.g != warmPx.g || srcPx.b != warmPx.b
        XCTAssertTrue(channelsDiffer, "White balance shift should change pixel colour")
    }

    // MARK: - Highlights / Shadows

    func testHighlightsShadows() {
        let source = makeGradientImage()
        let width = Int(source.extent.width)

        // Sample a bright pixel (near right edge) and a dark pixel (near left edge)
        let brightX = width - 4
        let darkX = 3
        let midY = Int(source.extent.height) / 2

        let srcBright = samplePixel(image: source, x: brightX, y: midY, context: ctx)
        let srcDark = samplePixel(image: source, x: darkX, y: midY, context: ctx)

        // Highlight recovery should darken bright pixels
        let hlResult = Renderer.render(source: source, editState: EditState(highlights: -50))
        let hlBright = samplePixel(image: hlResult, x: brightX, y: midY, context: ctx)
        XCTAssertLessThanOrEqual(hlBright.r, srcBright.r, "Highlight recovery should darken brights")

        // Shadow recovery should lift dark pixels
        let shResult = Renderer.render(source: source, editState: EditState(shadows: 50))
        let shDark = samplePixel(image: shResult, x: darkX, y: midY, context: ctx)
        XCTAssertGreaterThanOrEqual(shDark.r, srcDark.r, "Shadow recovery should lift darks")
    }

    // MARK: - Whites / Blacks

    func testWhitesBlacks() {
        let source = makeGradientImage()
        let width = Int(source.extent.width)
        let midY = Int(source.extent.height) / 2

        // Whites adjustment — sample near the bright end
        let brightX = width - 4
        let srcBright = samplePixel(image: source, x: brightX, y: midY, context: ctx)
        let whitesDown = Renderer.render(source: source, editState: EditState(whites: -50))
        let resBright = samplePixel(image: whitesDown, x: brightX, y: midY, context: ctx)
        XCTAssertLessThan(resBright.r, srcBright.r, "Negative whites should pull down bright values")

        // Blacks adjustment — sample at pure black (x=0) with strong adjustment
        let srcDark = samplePixel(image: source, x: 0, y: midY, context: ctx)
        let blacksUp = Renderer.render(source: source, editState: EditState(blacks: 100))
        let resDark = samplePixel(image: blacksUp, x: 0, y: midY, context: ctx)
        XCTAssertGreaterThan(resDark.r, srcDark.r, "Positive blacks should lift dark values")
    }

    // MARK: - Vibrance

    func testVibrance() {
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let width = Int(source.extent.width)

        // Sample muted pixel (left half) before and after vibrance boost
        let mutedX = width / 4
        let srcMuted = samplePixel(image: source, x: mutedX, y: midY, context: ctx)

        let result = Renderer.render(source: source, editState: EditState(vibrance: 80))
        let resMuted = samplePixel(image: result, x: mutedX, y: midY, context: ctx)

        // Vibrance should change the muted pixel
        let mChanged = srcMuted.r != resMuted.r || srcMuted.g != resMuted.g || srcMuted.b != resMuted.b
        XCTAssertTrue(mChanged, "Vibrance should shift muted colours")
    }

    // MARK: - Saturation

    func testSaturation() {
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let width = Int(source.extent.width)

        // Sample both halves
        let leftX = width / 4
        let rightX = 3 * width / 4
        let srcLeft = samplePixel(image: source, x: leftX, y: midY, context: ctx)
        let srcRight = samplePixel(image: source, x: rightX, y: midY, context: ctx)

        let result = Renderer.render(source: source, editState: EditState(saturation: 50))
        let resLeft = samplePixel(image: result, x: leftX, y: midY, context: ctx)
        let resRight = samplePixel(image: result, x: rightX, y: midY, context: ctx)

        // Both halves should change
        let leftChanged = srcLeft.r != resLeft.r || srcLeft.g != resLeft.g || srcLeft.b != resLeft.b
        let rightChanged = srcRight.r != resRight.r || srcRight.g != resRight.g || srcRight.b != resRight.b
        XCTAssertTrue(leftChanged, "Saturation should change muted region")
        XCTAssertTrue(rightChanged, "Saturation should change saturated region")
    }

    // MARK: - Crop

    func testCropChangesExtent() {
        let source = makeGradientImage(width: 64, height: 64)
        let cropRect = CGRect(x: 16, y: 16, width: 32, height: 32)
        let result = Renderer.render(source: source, editState: EditState(cropRect: cropRect))

        XCTAssertEqual(result.extent.width, 32, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 32, accuracy: 0.5)
        // Origin should be translated to (0,0)
        XCTAssertEqual(result.extent.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(result.extent.origin.y, 0, accuracy: 0.5)
    }

    func testCropAngleRotates() {
        let source = makeGradientImage(width: 64, height: 64)
        // Crop with a rotation — the extent geometry changes
        let cropRect = CGRect(x: 0, y: 0, width: 40, height: 40)
        let result = Renderer.render(
            source: source,
            editState: EditState(cropRect: cropRect, cropAngle: 5)
        )

        // With rotation + crop the output should exist and have the crop dimensions
        XCTAssertEqual(result.extent.width, 40, accuracy: 0.5)
        XCTAssertEqual(result.extent.height, 40, accuracy: 0.5)
    }

    // MARK: - Clarity

    func testClarityEnhancesLocalContrast() {
        // Use an image with a hard edge so the large-radius USM has detail to enhance
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        // Sample near the edge between the two halves
        let edgeX = Int(source.extent.width) / 2 - 1
        let srcPx = samplePixel(image: source, x: edgeX, y: midY, context: ctx)

        let result = Renderer.render(source: source, editState: EditState(clarity: 80))
        let resPx = samplePixel(image: result, x: edgeX, y: midY, context: ctx)

        // Clarity should produce a visible change near the edge
        let changed = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(changed, "Clarity should enhance local contrast near edges")
    }
}
