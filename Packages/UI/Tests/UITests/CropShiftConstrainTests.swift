import CoreGraphics
import EditEngine
@testable import UI
import XCTest

/// Tests for `CropViewModel.updateRect(overrideRatio:)` — the path
/// exercised by shift-drag in `.free` mode. Regression guard for
/// #156 Bug 4.
final class CropShiftConstrainTests: XCTestCase {

    /// Shift-drag in free mode: the override ratio must be honoured
    /// even though `selectedPreset == .free` would normally leave the
    /// rect unconstrained.
    @MainActor
    func testOverrideRatioLocksShapeInFreeMode() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.0, y: 0.0, width: 0.4, height: 0.2),
            angle: 0,
            imageAspect: 1.0
        )
        XCTAssertEqual(vm.selectedPreset, .free)

        // Drag the bottom-right handle out with Shift held: overlay
        // passes the starting rect's 2:1 ratio as the override. The
        // free-mode rect would otherwise stretch freely.
        let lockedRatio: Double = 2.0
        vm.updateRect(
            CGRect(x: 0.0, y: 0.0, width: 0.8, height: 0.2),
            anchor: CGPoint(x: 0.0, y: 0.0),
            overrideRatio: lockedRatio
        )

        XCTAssertEqual(
            vm.cropRect.width / vm.cropRect.height,
            lockedRatio,
            accuracy: 1e-9
        )
    }

    /// Override ratio also wins when a non-free preset is active — a
    /// single shift-drag can temporarily force a different ratio
    /// without mutating `selectedPreset`. (In practice the overlay
    /// only passes `overrideRatio` when `selectedPreset == .free`, but
    /// the API's contract — "override wins when non-nil" — is what
    /// we're locking down here.)
    @MainActor
    func testOverrideRatioBeatsSelectedPreset() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.0, y: 0.0, width: 0.6, height: 0.6),
            angle: 0,
            imageAspect: 1.0
        )
        vm.selectedPreset = .oneToOne

        let overrideRatio: Double = 16.0 / 9.0
        vm.updateRect(
            CGRect(x: 0.0, y: 0.0, width: 0.8, height: 0.8),
            anchor: CGPoint(x: 0.0, y: 0.0),
            overrideRatio: overrideRatio
        )

        XCTAssertEqual(
            vm.cropRect.width / vm.cropRect.height,
            overrideRatio,
            accuracy: 1e-9
        )
        // Preset is not mutated by the override — the caller
        // (overlay) retains ownership of preset state.
        XCTAssertEqual(vm.selectedPreset, .oneToOne)
    }

    /// Default argument: when overrideRatio is nil, existing preset
    /// behaviour is preserved (regression guard for the back-compat
    /// path — old callers must still work).
    @MainActor
    func testNilOverrideFallsBackToSelectedPreset() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.0, y: 0.0, width: 0.6, height: 0.6),
            angle: 0,
            imageAspect: 1.0
        )
        vm.selectedPreset = .oneToOne

        // No override passed — the call goes through the default-
        // argument path and the 1:1 preset must still apply.
        vm.updateRect(
            CGRect(x: 0.0, y: 0.0, width: 0.8, height: 0.4),
            anchor: CGPoint(x: 0.0, y: 0.0)
        )

        XCTAssertEqual(vm.cropRect.width, vm.cropRect.height, accuracy: 1e-9)
    }
}
