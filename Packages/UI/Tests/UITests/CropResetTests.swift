import CoreGraphics
import EditEngine
@testable import UI
import XCTest

/// Tests for `CropViewModel.resetRect()` — the double-click-to-reset
/// path introduced for #156. The reset must be non-destructive to the
/// `cancel()` baseline so Escape still reverts to the pre-activate
/// crop, and must leave `selectedPreset` untouched.
final class CropResetTests: XCTestCase {

    @MainActor
    func testResetRectSnapsToUnitSquare() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            angle: 0,
            imageAspect: 1.0
        )

        vm.resetRect()

        XCTAssertEqual(vm.cropRect.origin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.origin.y, 0, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.width, 1, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.height, 1, accuracy: 1e-9)
    }

    @MainActor
    func testResetRectLeavesSelectedPresetUntouched() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            angle: 0,
            imageAspect: 1.0
        )
        vm.selectedPreset = .threeToTwo

        vm.resetRect()

        XCTAssertEqual(vm.selectedPreset, .threeToTwo)
    }

    /// After a double-click reset the user can still press Escape
    /// (`cancel()`) to return to the crop they had before entering
    /// crop mode — not to the identity rect the reset produced.
    @MainActor
    func testCancelAfterResetStillRevertsToPreActivateRect() {
        let vm = CropViewModel()
        let preActivate = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        vm.cropRect = preActivate
        vm.activate(
            cropRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
            angle: 0,
            imageAspect: 1.0
        )

        vm.resetRect()
        vm.cancel()

        XCTAssertEqual(vm.cropRect.origin.x, preActivate.origin.x, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.origin.y, preActivate.origin.y, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.width, preActivate.width, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.height, preActivate.height, accuracy: 1e-9)
    }
}
