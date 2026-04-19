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

    func test_toggleFitTo100_from_fit_clamps_when_image_smaller_than_container() {
        // When the image is smaller than the container in both axes, fit >
        // 1.0, so "go to 100%" is below the minimum zoom and clampZoom
        // snaps back to fit — the toggle is a visible no-op. This invariant
        // is what bin/harness-zoom-flow.sh's fixture sizing relies on: the
        // library-seed JPEGs are chosen large enough (≥ container in at
        // least one axis) that fit ≤ 1.0 and toggling actually changes
        // isZoomed. A 256×256 image in the 1024×768 container reproduces
        // the original failure mode.
        let smallImage = CGSize(width: 256, height: 256)
        let fit = ZoomState.fitScale(imageSize: smallImage, containerSize: container)
        XCTAssertGreaterThan(fit, 1.0, "precondition: fit must exceed 1.0")
        var state = ZoomState(zoomScale: fit)
        state.toggleFitTo100(imageSize: smallImage, containerSize: container)
        XCTAssertEqual(state.zoomScale, fit, accuracy: 0.001)
        XCTAssertTrue(state.isAtFit(imageSize: smallImage, containerSize: container))
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

    // MARK: - applyPan

    func test_applyPan_noop_at_fit() {
        // At fit scale there is no room to pan — deltas should be ignored
        // and panOffset should stay at zero.
        let fit = ZoomState.fitScale(imageSize: landscape, containerSize: container)
        var state = ZoomState(zoomScale: fit)
        state.applyPan(dx: 50, dy: 50, imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.panOffset, .zero)
    }

    func test_applyPan_noop_when_zoomScale_is_zero_sentinel() {
        // The zoomScale==0 sentinel also means fit; applyPan must no-op.
        var state = ZoomState(zoomScale: 0)
        state.applyPan(dx: 50, dy: 50, imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.zoomScale, 0)
        XCTAssertEqual(state.panOffset, .zero)
    }

    func test_applyPan_translates_when_zoomed() {
        // At 2× on a landscape image, there is ample room to pan in
        // both axes (clamp in test_clampPan_at_zoom_prevents_overscroll:
        // maxOffsetX=1536, maxOffsetY=981). A small delta should land
        // entirely within those bounds so clamping does not interfere.
        var state = ZoomState(zoomScale: 2.0)
        state.applyPan(dx: 10, dy: 20, imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.panOffset.width, 10, accuracy: 0.001)
        // Sign convention: +dy (scrollingDeltaY positive, i.e. swipe up
        // with natural scrolling) moves the image up in the viewport,
        // which in SwiftUI `.offset` coordinates means panOffset.height
        // decreases. See test_applyPan_sign_matches_natural_scrolling.
        XCTAssertEqual(state.panOffset.height, -20, accuracy: 0.001)
    }

    func test_applyPan_clamps_at_edge() {
        // A large delta must be clamped to the same max offset as
        // clampPan (maxOffsetX=1536, maxOffsetY=-981).
        var state = ZoomState(zoomScale: 2.0)
        state.applyPan(dx: 5000, dy: 5000, imageSize: landscape, containerSize: container)
        XCTAssertEqual(state.panOffset.width, 1536, accuracy: 0.5)
        // +dy large → panOffset.height large negative → clamped to -981.
        XCTAssertEqual(state.panOffset.height, -981, accuracy: 0.5)
    }

    func test_applyPan_sign_matches_natural_scrolling() {
        // Lock in the chosen sign convention so a future refactor does
        // not silently invert direction.
        //
        // With macOS "natural scrolling" ON (the default), swiping two
        // fingers up on the trackpad gives a POSITIVE scrollingDeltaY.
        // The user expects this to move the image UP in the viewport
        // (revealing content that was below), matching Preview/Photos.
        //
        // In SwiftUI `.offset(y: N)`, positive N moves the image DOWN.
        // So a positive dy must DECREASE panOffset.height.
        //
        // Horizontal works the other way: positive scrollingDeltaX
        // (swipe right with natural scrolling) moves the image RIGHT,
        // which in SwiftUI `.offset` is an INCREASE in panOffset.width.
        var state = ZoomState(zoomScale: 2.0)
        state.applyPan(dx: 1, dy: 1, imageSize: landscape, containerSize: container)
        XCTAssertGreaterThan(state.panOffset.width, 0,
            "Positive dx should increase panOffset.width (image moves right)")
        XCTAssertLessThan(state.panOffset.height, 0,
            "Positive dy should decrease panOffset.height (image moves up)")
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
