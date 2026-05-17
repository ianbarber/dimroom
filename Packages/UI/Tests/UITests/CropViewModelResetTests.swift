import CoreGraphics
import EditEngine
@testable import UI
import XCTest

/// Regression coverage for issue #239 bug 2: switching the active asset
/// must clear all crop overlay state so a fresh, never-cropped photo
/// shows the full frame instead of the prior asset's crop.
final class CropViewModelResetTests: XCTestCase {

    @MainActor
    func testResetToIdentityClearsAllState() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
            angle: 12,
            imageAspect: 1.5
        )
        vm.selectedPreset = .threeToTwo

        vm.resetToIdentity()

        XCTAssertEqual(vm.cropRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(vm.cropAngle, 0)
        XCTAssertEqual(vm.selectedPreset, .free)
        XCTAssertFalse(vm.isActive)
    }

    /// Calling `resetToIdentity` mid-session must clear `isActive` so a
    /// stale `cancel()` can't revive the prior rect (the cancel snapshot
    /// is dropped along with the rect).
    @MainActor
    func testResetToIdentityWhileActiveDropsCancelSnapshot() {
        let vm = CropViewModel()
        vm.cropRect = CGRect(x: 0.0, y: 0.0, width: 0.6, height: 0.6)
        vm.activate(
            cropRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            angle: 5,
            imageAspect: 1.0
        )
        XCTAssertTrue(vm.isActive)

        vm.resetToIdentity()

        // A subsequent cancel must not revive the pre-activate rect — the
        // snapshot was cleared along with everything else.
        vm.cropRect = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        vm.cancel()

        XCTAssertEqual(
            vm.cropRect,
            CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            "cancel after reset must not restore the prior snapshot"
        )
        XCTAssertFalse(vm.isActive)
    }

    /// After reset, a fresh `activate()` with a different aspect must
    /// override `imageAspect` cleanly so preset math for the new image
    /// doesn't reuse the prior asset's aspect.
    @MainActor
    func testResetThenActivateWithNewAspectUpdatesImageAspect() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            angle: 0,
            imageAspect: 3.0 / 2.0
        )
        XCTAssertEqual(vm.imageAspect, 1.5, accuracy: 1e-9)

        vm.resetToIdentity()
        XCTAssertEqual(vm.imageAspect, 1.0, accuracy: 1e-9)

        vm.activate(
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            angle: 0,
            imageAspect: 16.0 / 9.0
        )
        XCTAssertEqual(vm.imageAspect, 16.0 / 9.0, accuracy: 1e-9)
    }
}
