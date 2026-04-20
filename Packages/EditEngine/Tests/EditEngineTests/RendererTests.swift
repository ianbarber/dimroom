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
        // Sample ¾-bright rather than dead centre — CIColorControls pivots
        // contrast around 0.5, so a pixel right at 0.5 is invariant. Anything
        // off the pivot should shift under a positive contrast boost.
        let sampleX = Int(source.extent.width) * 3 / 4
        let midY = Int(source.extent.height) / 2

        let result = Renderer.render(source: source, editState: EditState(contrast: 50))
        let srcPx = samplePixel(image: source, x: sampleX, y: midY, context: ctx)
        let resPx = samplePixel(image: result, x: sampleX, y: midY, context: ctx)

        XCTAssertNotEqual(srcPx.r, resPx.r, "Contrast should change off-pivot values")
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

    func testCropAngleRotatesAroundCenter() {
        let source = makeGradientImage(width: 64, height: 64)
        let mid = Int(source.extent.width) / 2

        // Sample the center pixel of the unrotated source
        let srcCenter = samplePixel(image: source, x: mid, y: mid, context: ctx)

        // Full-image crop with a small rotation — pivot should be at image center
        let cropRect = source.extent
        let result = Renderer.render(
            source: source,
            editState: EditState(cropRect: cropRect, cropAngle: 5)
        )

        // After center-pivot rotation the center pixel should stay the same
        let resCenter = samplePixel(image: result, x: mid, y: mid, context: ctx)
        XCTAssertEqual(resCenter.r, srcCenter.r, "Center pixel R should be unchanged after center-pivot rotation")
        XCTAssertEqual(resCenter.g, srcCenter.g, "Center pixel G should be unchanged after center-pivot rotation")
        XCTAssertEqual(resCenter.b, srcCenter.b, "Center pixel B should be unchanged after center-pivot rotation")
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

    func testNegativeClarityProducesSoftening() {
        // Negative clarity should reduce local contrast (move edge pixel toward neighbours' mean)
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let edgeX = Int(source.extent.width) / 2 - 1
        let srcPx = samplePixel(image: source, x: edgeX, y: midY, context: ctx)

        let result = Renderer.render(source: source, editState: EditState(clarity: -80))
        let resPx = samplePixel(image: result, x: edgeX, y: midY, context: ctx)

        // The edge pixel is on the muted-red side (R=160, G=120, B=120).
        // Its neighbour across the edge is saturated blue (R=0, G=0, B=240).
        // Softening should pull the red channel down toward the mean and the
        // blue channel up toward the mean — i.e., local contrast decreases.
        let changed = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(changed, "Negative clarity should visibly change the edge pixel")

        // The muted-red pixel's R should decrease (blending toward blue side)
        XCTAssertLessThan(resPx.r, srcPx.r, "Negative clarity should soften: red channel moves toward neighbour mean")
    }

    // MARK: - Range calibration
    //
    // These tests pin the remap introduced in #127. The old mapping (±100 →
    // ±full filter range) pushed most useful edits into a small slice of
    // slider travel; the new mapping halves the slope so full travel covers
    // the practical editing range. Tests assert the extremes are *bounded*
    // — strong, but not clipped to 0/1 — and midpoints remain identity.

    func testContrastExtremesAreBounded() {
        let source = makeGradientImage()
        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2

        let maxed = Renderer.render(source: source, editState: EditState(contrast: 100))
        let maxPx = samplePixel(image: maxed, x: midX, y: midY, context: ctx)
        // Midtone (~0.5) should still be inside the usable band at ±100.
        XCTAssertGreaterThan(maxPx.r, 20, "+100 contrast should not crush midtones to black")
        XCTAssertLessThan(maxPx.r, 240, "+100 contrast should not blow midtones to white")

        let crushed = Renderer.render(source: source, editState: EditState(contrast: -100))
        let lowPx = samplePixel(image: crushed, x: midX, y: midY, context: ctx)
        XCTAssertGreaterThan(lowPx.r, 40, "-100 contrast should not crush to black")
        XCTAssertLessThan(lowPx.r, 220, "-100 contrast should not wash to white")
    }

    func testContrastSymmetry() {
        let source = makeGradientImage()
        let width = Int(source.extent.width)
        let midY = Int(source.extent.height) / 2

        // Sample a bright pixel — +contrast pushes it up, -contrast pulls it down.
        let brightX = width - 4
        let srcBright = samplePixel(image: source, x: brightX, y: midY, context: ctx)
        let posBright = samplePixel(
            image: Renderer.render(source: source, editState: EditState(contrast: 100)),
            x: brightX, y: midY, context: ctx
        )
        let negBright = samplePixel(
            image: Renderer.render(source: source, editState: EditState(contrast: -100)),
            x: brightX, y: midY, context: ctx
        )

        XCTAssertGreaterThan(Int(posBright.r), Int(srcBright.r), "+contrast should push bright pixel higher")
        XCTAssertLessThan(Int(negBright.r), Int(srcBright.r), "-contrast should pull bright pixel lower")
    }

    func testHighlightsExtremesAreBounded() {
        let source = makeGradientImage()
        let width = Int(source.extent.width)
        let midY = Int(source.extent.height) / 2
        let brightX = width - 4

        let down = Renderer.render(source: source, editState: EditState(highlights: -100))
        let downPx = samplePixel(image: down, x: brightX, y: midY, context: ctx)
        // Full highlight recovery must lower the bright pixel but not black it out.
        XCTAssertGreaterThan(downPx.r, 60, "-100 highlights should not crush brights to black")

        let up = Renderer.render(source: source, editState: EditState(highlights: 100))
        let upPx = samplePixel(image: up, x: brightX, y: midY, context: ctx)
        XCTAssertGreaterThan(upPx.r, 180, "+100 highlights should keep brights strong")
    }

    func testShadowsExtremesAreBounded() {
        let source = makeGradientImage()
        let midY = Int(source.extent.height) / 2
        let darkX = 3

        let up = Renderer.render(source: source, editState: EditState(shadows: 100))
        let upPx = samplePixel(image: up, x: darkX, y: midY, context: ctx)
        // +100 shadows should lift the dark pixel noticeably but not whiteout.
        XCTAssertGreaterThan(upPx.r, 15, "+100 shadows should lift darks above source level")
        XCTAssertLessThan(upPx.r, 220, "+100 shadows should not wash darks to white")

        let down = Renderer.render(source: source, editState: EditState(shadows: -100))
        let downPx = samplePixel(image: down, x: darkX, y: midY, context: ctx)
        XCTAssertLessThan(downPx.r, 80, "-100 shadows should deepen darks")
    }

    func testWhitesBlacksExtremesAreBounded() {
        let source = makeGradientImage()
        let width = Int(source.extent.width)
        let midY = Int(source.extent.height) / 2

        // Blacks at +100 lifts the (0,0) curve point; at -100 it sits at 0.
        let blacksUp = Renderer.render(source: source, editState: EditState(blacks: 100))
        let blacksUpPx = samplePixel(image: blacksUp, x: 0, y: midY, context: ctx)
        XCTAssertGreaterThan(blacksUpPx.r, 10, "+100 blacks should lift the black point off zero")
        XCTAssertLessThan(blacksUpPx.r, 120, "+100 blacks should not drag the black point halfway up")

        // Whites at -100 pulls the (1,1) curve point down; bright pixel should drop.
        let brightX = width - 4
        let srcBright = samplePixel(image: source, x: brightX, y: midY, context: ctx)
        let whitesDown = Renderer.render(source: source, editState: EditState(whites: -100))
        let whitesDownPx = samplePixel(image: whitesDown, x: brightX, y: midY, context: ctx)
        XCTAssertLessThan(whitesDownPx.r, srcBright.r, "-100 whites should pull bright pixel down")
        XCTAssertGreaterThan(whitesDownPx.r, 120, "-100 whites should not crush brights below midline")
    }

    func testClarityMaxIsBounded() {
        // At ±100 the edge pixel still moves, but the magnitude is lower than
        // the unclamped pre-fix ratio (intensity 1.0) would have produced.
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let edgeX = Int(source.extent.width) / 2 - 1
        let srcPx = samplePixel(image: source, x: edgeX, y: midY, context: ctx)

        let positive = Renderer.render(source: source, editState: EditState(clarity: 100))
        let posPx = samplePixel(image: positive, x: edgeX, y: midY, context: ctx)
        XCTAssertNotEqual(posPx.r, srcPx.r, "+100 clarity should still move the edge pixel")

        let negative = Renderer.render(source: source, editState: EditState(clarity: -100))
        let negPx = samplePixel(image: negative, x: edgeX, y: midY, context: ctx)
        // Negative clarity blends toward blur; keep the softened pixel distinguishable
        // from pure blur (blendFraction clamped at 0.5 not 1.0).
        XCTAssertGreaterThan(Int(negPx.r), Int(srcPx.r) / 3, "-100 clarity should not collapse toward neighbour mean")
    }

    func testVibranceMidpointIsIdentity() {
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let width = Int(source.extent.width)
        let leftX = width / 4
        let srcPx = samplePixel(image: source, x: leftX, y: midY, context: ctx)
        let resPx = samplePixel(
            image: Renderer.render(source: source, editState: EditState(vibrance: 0)),
            x: leftX, y: midY, context: ctx
        )
        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }

    func testSaturationMidpointIsIdentity() {
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let width = Int(source.extent.width)
        let leftX = width / 4
        let srcPx = samplePixel(image: source, x: leftX, y: midY, context: ctx)
        let resPx = samplePixel(
            image: Renderer.render(source: source, editState: EditState(saturation: 0)),
            x: leftX, y: midY, context: ctx
        )
        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }

    func testSaturationExtremesAreBounded() {
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let width = Int(source.extent.width)

        // -100 saturation should fully desaturate: R, G, B channels equal within rounding.
        let desat = Renderer.render(source: source, editState: EditState(saturation: -100))
        let desatPx = samplePixel(image: desat, x: width / 4, y: midY, context: ctx)
        // Muted red (160, 120, 120) becomes luminance-grey — channels should be close.
        XCTAssertEqual(Int(desatPx.r), Int(desatPx.g), accuracy: 4)
        XCTAssertEqual(Int(desatPx.g), Int(desatPx.b), accuracy: 4)

        // +100 saturation should boost but keep channels in 0…255.
        let boosted = Renderer.render(source: source, editState: EditState(saturation: 100))
        let boostedPx = samplePixel(image: boosted, x: 3 * width / 4, y: midY, context: ctx)
        // Saturated blue input (0, 0, 240): boost should not wrap / invert.
        XCTAssertLessThan(boostedPx.r, 120, "+100 saturation should not shift hue of pure blue")
        XCTAssertGreaterThan(boostedPx.b, 200, "+100 saturation should keep blue channel strong")
    }

    // MARK: - Sharpening

    func testSharpeningIdentityIsNoOp() {
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let edgeX = Int(source.extent.width) / 2 - 1

        let srcPx = samplePixel(image: source, x: edgeX, y: midY, context: ctx)
        let result = Renderer.render(source: source, editState: EditState(sharpening: 0))
        let resPx = samplePixel(image: result, x: edgeX, y: midY, context: ctx)

        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }

    func testSharpeningChangesPixels() {
        // CISharpenLuminance enhances contrast on luminance edges. The
        // edge pixel in makeColorImage should visibly change under strong
        // sharpening.
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let edgeX = Int(source.extent.width) / 2 - 1

        let srcPx = samplePixel(image: source, x: edgeX, y: midY, context: ctx)
        let result = Renderer.render(source: source, editState: EditState(sharpening: 80))
        let resPx = samplePixel(image: result, x: edgeX, y: midY, context: ctx)

        let changed = srcPx.r != resPx.r || srcPx.g != resPx.g || srcPx.b != resPx.b
        XCTAssertTrue(changed, "Sharpening should change edge pixels")
    }

    // MARK: - Vignette

    func testVignetteIdentityIsNoOp() {
        let source = makeGradientImage()
        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2

        let srcPx = samplePixel(image: source, x: midX, y: midY, context: ctx)
        let result = Renderer.render(source: source, editState: EditState(vignetteAmount: 0))
        let resPx = samplePixel(image: result, x: midX, y: midY, context: ctx)

        XCTAssertEqual(srcPx.r, resPx.r)
        XCTAssertEqual(srcPx.g, resPx.g)
        XCTAssertEqual(srcPx.b, resPx.b)
    }

    func testDarkVignetteDarkensCorners() {
        // A grey source so both darkening and lightening are detectable.
        let source = makeMidGreyImage()
        let cornerX = 2
        let cornerY = 2
        let midX = Int(source.extent.width) / 2
        let midY = Int(source.extent.height) / 2

        let srcCorner = samplePixel(image: source, x: cornerX, y: cornerY, context: ctx)
        let srcCenter = samplePixel(image: source, x: midX, y: midY, context: ctx)

        let result = Renderer.render(
            source: source,
            editState: EditState(vignetteAmount: -100)
        )
        let resCorner = samplePixel(image: result, x: cornerX, y: cornerY, context: ctx)
        let resCenter = samplePixel(image: result, x: midX, y: midY, context: ctx)

        XCTAssertLessThan(resCorner.r, srcCorner.r, "Negative vignette should darken corners")
        // Centre should be largely unaffected — the radial mask's black disc
        // covers the middle.
        XCTAssertEqual(Int(resCenter.r), Int(srcCenter.r), accuracy: 10)
    }

    func testLightVignetteBrightensCorners() {
        let source = makeMidGreyImage()
        let cornerX = 2
        let cornerY = 2
        let srcCorner = samplePixel(image: source, x: cornerX, y: cornerY, context: ctx)

        let result = Renderer.render(
            source: source,
            editState: EditState(vignetteAmount: 100)
        )
        let resCorner = samplePixel(image: result, x: cornerX, y: cornerY, context: ctx)

        XCTAssertGreaterThan(resCorner.r, srcCorner.r, "Positive vignette should brighten corners")
    }

    func testClaritySymmetry() {
        // Positive and negative clarity should move the same edge pixel in opposite directions
        let source = makeColorImage()
        let midY = Int(source.extent.height) / 2
        let edgeX = Int(source.extent.width) / 2 - 1
        let srcPx = samplePixel(image: source, x: edgeX, y: midY, context: ctx)

        let positive = Renderer.render(source: source, editState: EditState(clarity: 50))
        let negative = Renderer.render(source: source, editState: EditState(clarity: -50))
        let posPx = samplePixel(image: positive, x: edgeX, y: midY, context: ctx)
        let negPx = samplePixel(image: negative, x: edgeX, y: midY, context: ctx)

        // Positive clarity sharpens (increases local contrast): the muted-red edge pixel's
        // R channel should increase (pushed away from the blue neighbour).
        // Negative clarity softens (decreases local contrast): R should decrease (pulled
        // toward the blue neighbour's mean).
        let positiveDelta = Int(posPx.r) - Int(srcPx.r)
        let negativeDelta = Int(negPx.r) - Int(srcPx.r)

        // They should move in opposite directions
        XCTAssertGreaterThan(positiveDelta, 0, "Positive clarity should push edge pixel away from neighbour")
        XCTAssertLessThan(negativeDelta, 0, "Negative clarity should pull edge pixel toward neighbour")
    }
}
