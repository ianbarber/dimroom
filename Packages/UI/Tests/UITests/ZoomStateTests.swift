@testable import UI
import XCTest

/// Layer A tests for `ZoomState` — pure logic, no views, no snapshots.
final class ZoomStateTests: XCTestCase {

    // Common test sizes.
    private let landscape = CGSize(width: 2048, height: 1365)
    private let portrait = CGSize(width: 1365, height: 2048)
    private let container = CGSize(width: 1024, height: 768)

    // MARK: - fitScale

    func test_fitScale_landscape() {
        // 2048×1365 image in 1024×768 container.
        // width ratio = 1024/2048 = 0.5
        // height ratio = 768/1365 ≈ 0.5626
        // fit = min(0.5, 0.5626) = 0.5
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        XCTAssertEqual(fit, 0.5, accuracy: 0.001)
    }

    func test_fitScale_portrait() {
        // 1365×2048 image in 1024×768 container.
        // width ratio = 1024/1365 ≈ 0.750
        // height ratio = 768/2048 = 0.375
        // fit = min(0.750, 0.375) = 0.375
        let fit = ZoomState.fitScale(imageSize: portrait, containerSize: container)
        XCTAssertEqual(fit, 0.375, accuracy: 0.001)
    }

    // MARK: - clampZoom

    func test_clampZoom_below_fit() {
        var state = ZoomState(zoomScale: 0.1)
        state.clampZoom(imageSize: landscape, containerSize: container)
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, fit, accuracy: 0.001)
    }

    func test_clampZoom_above_max() {
        var state = ZoomState(zoomScale: 10.0)
        state.clampZoom(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, ZoomState.maxZoom, accuracy: 0.001)
    }

    // MARK: - toggleFitTo100

    func test_toggleFitTo100_from_fit() {
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        var state = ZoomState(zoomScale: fit)
        state.toggleFitTo100(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, 1.0, accuracy: 0.001)
    }

    func test_toggleFitTo100_from_100() {
        var state = ZoomState(zoomScale: 1.0)
        state.toggleFitTo100(imageSize: landscape, containerSize: container)
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, fit, accuracy: 0.001)
        XCTAssertEqual(state.panOffset, .zero)
    }

    // MARK: - resetToFit

    func test_resetToFit() {
        var state = ZoomState(
            zoomScale: 2.0,
            panOffset: CGSize(width: 100, height: -50)
        )
        state.resetToFit(imageSize: landscape, containerSize: container)
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, fit, accuracy: 0.001)
        XCTAssertEqual(state.panOffset, .zero)
    }

    // MARK: - clampPan

    func test_clampPan_at_fit() {
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        var state = ZoomState(
            zoomScale: fit,
            panOffset: CGSize(width: 100, height: 100)
        )
        state.clampPan(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.panOffset.width, 0, accuracy: 0.001)
        XCTAssertEqual(state.panOffset.height, 0, accuracy: 0.001)
    }

    func test_clampPan_at_zoom_prevents_overscroll() {
        // At 2.0×, the scaled image is 2048*2=4096 wide, 1365*2=2730 tall.
        // Container is 1024×768.
        // maxOffsetX = (4096 - 1024) / 2 = 1536
        // maxOffsetY = (2730 - 768) / 2 = 981
        var state = ZoomState(
            zoomScale: 2.0,
            panOffset: CGSize(width: 5000, height: -5000)
        )
        state.clampPan(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.panOffset.width, 1536, accuracy: 0.5)
        XCTAssertEqual(state.panOffset.height, -981, accuracy: 0.5)
    }

    // MARK: - applyMagnification

    func test_apply_magnification_scales_around_anchor() {
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        var state = ZoomState(zoomScale: fit)
        // Pinch to 2× starting from fit (0.5), centred.
        let magnification: CGFloat = 2.0 / fit  // target / start
        state.applyMagnification(
            magnification,
            anchor: CGPoint(x: 0.5, y: 0.5),
            startScale: fit,
            imageSize: landscape,
            containerSize: container
        )
        XCTAssertEqual(state.zoomScale, 2.0, accuracy: 0.01)
    }

    // MARK: - Zero-scale sentinel

    func test_isAtFit_when_zoomScale_is_zero() {
        let state = ZoomState(zoomScale: 0)
        XCTAssertTrue(state.isAtFit(imageSize: landscape, containerSize: container))
    }

    func test_toggleFitTo100_from_zero_scale() {
        // A single toggle from the initial zoomScale==0 sentinel should
        // jump straight to 1.0 (100%), not silently stay at fit.
        var state = ZoomState(zoomScale: 0)
        state.toggleFitTo100(imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, 1.0, accuracy: 0.001)
    }

    func test_applyScrollZoom_from_zero_scale() {
        // Scroll-zoom from the 0 sentinel should resolve to fit first,
        // then apply the delta — result must be non-zero and near fit.
        var state = ZoomState(zoomScale: 0)
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        state.applyScrollZoom(delta: 5.0, imageSize: landscape, containerSize: container)
        XCTAssertGreaterThan(state.zoomScale, 0)
        // Should be close to fit × 1.05 (delta 5 × 0.01 factor).
        XCTAssertEqual(state.zoomScale, fit * 1.05, accuracy: 0.01)
    }

    // MARK: - displayLabel

    func test_zoomDisplayLabel() {
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)

        let atFit = ZoomState(zoomScale: fit)
        XCTAssertEqual(
            atFit.displayLabel(imageSize: landscape, containerSize: container),
            "Fit"
        )

        let at100 = ZoomState(zoomScale: 1.0)
        XCTAssertEqual(
            at100.displayLabel(imageSize: landscape, containerSize: container),
            "100%"
        )

        let at200 = ZoomState(zoomScale: 2.0)
        XCTAssertEqual(
            at200.displayLabel(imageSize: landscape, containerSize: container),
            "200%"
        )

        let at47 = ZoomState(zoomScale: 0.47)
        XCTAssertEqual(
            at47.displayLabel(imageSize: landscape, containerSize: container),
            "47%"
        )
    }
}
