import Foundation
@testable import UI
import XCTest

/// Tests for `AspectRatioPreset.ratio(imageAspect:)` — the
/// normalised-space ratio that `CropGeometry.constrain` uses to
/// enforce the preset. The returned value must be `pixelRatio /
/// imageAspect` so that the resulting crop is pixel-accurate on
/// non-square images.
final class AspectRatioPresetTests: XCTestCase {

    // MARK: - free / original

    func testFreeIsUnconstrained() {
        XCTAssertNil(AspectRatioPreset.free.ratio(imageAspect: 1.0))
        XCTAssertNil(AspectRatioPreset.free.ratio(imageAspect: 0.75))
    }

    /// `.original` must collapse to a normalised ratio of 1 — a
    /// normalised-square rect on any image renders as the same
    /// pixel aspect as the source.
    func testOriginalCollapsesToOneForAnyAspect() {
        for aspect in [0.5, 0.75, 1.0, 1.5, 2.0] {
            XCTAssertEqual(
                AspectRatioPreset.original.ratio(imageAspect: aspect) ?? 0,
                1.0,
                accuracy: 1e-9,
                "original preset on aspect \(aspect)"
            )
        }
    }

    // MARK: - Pixel-accurate conversions

    /// Square image: preset's pixel ratio passes through unchanged.
    func testPresetsOnSquareImageReturnPixelRatioDirectly() {
        let aspect = 1.0
        XCTAssertEqual(AspectRatioPreset.oneToOne.ratio(imageAspect: aspect) ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(AspectRatioPreset.fourToThree.ratio(imageAspect: aspect) ?? 0, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(AspectRatioPreset.threeToTwo.ratio(imageAspect: aspect) ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(AspectRatioPreset.sixteenToNine.ratio(imageAspect: aspect) ?? 0, 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(AspectRatioPreset.fiveToFour.ratio(imageAspect: aspect) ?? 0, 1.25, accuracy: 1e-9)
    }

    /// Portrait image (aspect 0.75): `.oneToOne` must return >1 so
    /// the normalised rect is wider than tall and lands at an equal
    /// pixel width and height.
    func testOneToOneOnPortraitReturnsGreaterThanOne() {
        let aspect = 3.0 / 4.0 // 48×64-style portrait
        let ratio = AspectRatioPreset.oneToOne.ratio(imageAspect: aspect)
        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio ?? 0, 1.0 / aspect, accuracy: 1e-9)
        XCTAssertGreaterThan(ratio ?? 0, 1.0)
    }

    /// Landscape image: `.oneToOne` returns <1 so the normalised
    /// rect is taller than wide.
    func testOneToOneOnLandscapeReturnsLessThanOne() {
        let aspect = 16.0 / 9.0
        let ratio = AspectRatioPreset.oneToOne.ratio(imageAspect: aspect)
        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio ?? 0, 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertLessThan(ratio ?? 0, 1.0)
    }

    /// Degenerate: zero or negative aspect returns nil so
    /// `CropGeometry.constrain` falls back to a free crop rather
    /// than dividing by zero.
    func testDegenerateImageAspectReturnsNil() {
        XCTAssertNil(AspectRatioPreset.oneToOne.ratio(imageAspect: 0))
        XCTAssertNil(AspectRatioPreset.fourToThree.ratio(imageAspect: -1))
    }
}
