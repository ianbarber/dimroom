import Catalog
import CoreGraphics
import Foundation
@testable import UI
import XCTest

final class EditStateDescriptionTests: XCTestCase {

    func testIdenticalStatesReturnNil() {
        var state = EditState()
        state.exposure = 1.0
        XCTAssertNil(editParameterDescription(previous: state, next: state))
    }

    func testNilPreviousAgainstIdentityNextReturnsNil() {
        XCTAssertNil(editParameterDescription(previous: nil, next: EditState()))
    }

    func testNilPreviousWithSingleScalarChange() {
        var next = EditState()
        next.exposure = 2.0
        XCTAssertEqual(
            editParameterDescription(previous: nil, next: next),
            "Exposure +2.00"
        )
    }

    func testNegativeExposureFormat() {
        let previous = EditState()
        var next = EditState()
        next.exposure = -1.5
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Exposure -1.50"
        )
    }

    func testIntegerStepScalarPositive() {
        let previous = EditState()
        var next = EditState()
        next.contrast = 15
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Contrast +15"
        )
    }

    func testIntegerStepScalarReturnToZero() {
        var previous = EditState()
        previous.contrast = 20
        let next = EditState()
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Contrast +0"
        )
    }

    func testTemperatureAbsoluteFormat() {
        var previous = EditState()
        previous.temperature = 6500
        var next = EditState()
        next.temperature = 5500
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Temperature 5500K"
        )
    }

    func testCropRectOnlyChangeReportsCrop() {
        let previous = EditState()
        var next = EditState()
        next.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Crop"
        )
    }

    func testCropAngleOnlyChangeReportsCrop() {
        let previous = EditState()
        var next = EditState()
        next.cropAngle = 5
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Crop"
        )
    }

    func testCropRectAndAngleChangingTogetherCountsAsOneChange() {
        let previous = EditState()
        var next = EditState()
        next.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        next.cropAngle = 3
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Crop"
        )
    }

    func testCropPlusScalarChangeFallsBackToNil() {
        let previous = EditState()
        var next = EditState()
        next.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        next.exposure = 1.0
        XCTAssertNil(editParameterDescription(previous: previous, next: next))
    }

    func testTwoScalarChangesReturnNil() {
        let previous = EditState()
        var next = EditState()
        next.exposure = 1.0
        next.contrast = 10
        XCTAssertNil(editParameterDescription(previous: previous, next: next))
    }

    func testSplitToneHighlightHueReportsLabel() {
        let previous = EditState()
        var next = EditState()
        next.splitToneHighlightHue = 30
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Split Tone Highlight Hue +30"
        )
    }

    func testSplitToneBalanceReportsLabel() {
        let previous = EditState()
        var next = EditState()
        next.splitToneBalance = -25
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Split Tone Balance -25"
        )
    }

    func testTintChangeReportsSignedLabel() {
        let previous = EditState()
        var next = EditState()
        next.tint = -12
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Tint -12"
        )
    }

    func testHSLHueSingleBandReportsRangeName() {
        let previous = EditState()
        var next = EditState()
        next.hueShift[0] = 12 // Red
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Hue (Red) +12"
        )
    }

    func testHSLSaturationSingleBandReportsRangeName() {
        let previous = EditState()
        var next = EditState()
        next.hslSaturation[3] = -50 // Green
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Saturation (Green) -50"
        )
    }

    func testHSLMultipleBandsRollUpToGenericHSL() {
        let previous = EditState()
        var next = EditState()
        next.hueShift[0] = 10
        next.hueShift[3] = -10
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "HSL"
        )
    }

    // MARK: - Curves

    func testLuminanceCurveOnlyChangeReportsLabel() {
        let previous = EditState()
        var next = EditState()
        next.toneCurvePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.7),
            CGPoint(x: 1, y: 1)
        ]
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Luminance Curve"
        )
    }

    func testRedCurveOnlyChangeReportsLabel() {
        let previous = EditState()
        var next = EditState()
        next.redCurvePoints = [
            CGPoint(x: 0, y: 0.05),
            CGPoint(x: 1, y: 1)
        ]
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Red Curve"
        )
    }

    func testGreenCurveOnlyChangeReportsLabel() {
        let previous = EditState()
        var next = EditState()
        next.greenCurvePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.3),
            CGPoint(x: 1, y: 1)
        ]
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Green Curve"
        )
    }

    func testBlueCurveOnlyChangeReportsLabel() {
        let previous = EditState()
        var next = EditState()
        next.blueCurvePoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0.85)
        ]
        XCTAssertEqual(
            editParameterDescription(previous: previous, next: next),
            "Blue Curve"
        )
    }

    func testTwoCurvesChangedFallsBackToNil() {
        let previous = EditState()
        var next = EditState()
        next.toneCurvePoints = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.4), CGPoint(x: 1, y: 1)]
        next.redCurvePoints = [CGPoint(x: 0, y: 0.1), CGPoint(x: 1, y: 1)]
        XCTAssertNil(editParameterDescription(previous: previous, next: next))
    }
}
