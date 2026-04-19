import CoreGraphics
import EditEngine
@testable import UI
import XCTest

final class CropViewModelTests: XCTestCase {

    // MARK: - translateRect

    /// Regression: translation while a preset is active must preserve
    /// width/height and only shift the origin. Routing translation through
    /// `updateRect` (which applies the aspect-ratio constraint) used to
    /// teleport the rect because `CropGeometry.constrain` snaps the origin
    /// to `anchor - targetSize` when the anchor is at the rect's midpoint.
    @MainActor
    func testTranslateRectWithThreeToTwoPresetPreservesShape() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
            angle: 0,
            imageAspect: 1.0
        )
        vm.selectedPreset = .threeToTwo

        let translated = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.4)
        vm.translateRect(translated)

        XCTAssertEqual(vm.cropRect.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.height, 0.4, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.origin.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.origin.y, 0.25, accuracy: 1e-9)
    }

    @MainActor
    func testTranslateRectClampsToUnitBounds() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.0, y: 0.0, width: 0.4, height: 0.4),
            angle: 0,
            imageAspect: 1.0
        )
        vm.selectedPreset = .oneToOne

        // Translate past the right edge — width must remain 0.4 and the
        // origin must be clamped so maxX <= 1.
        vm.translateRect(CGRect(x: 0.9, y: 0.5, width: 0.4, height: 0.4))

        XCTAssertEqual(vm.cropRect.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.height, 0.4, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.maxX, 1.0, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.maxY, 0.9, accuracy: 1e-9)
    }

    // MARK: - updateRect (sanity: still applies preset)

    @MainActor
    func testUpdateRectWithPresetStillEnforcesRatio() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.0, y: 0.0, width: 0.6, height: 0.6),
            angle: 0,
            imageAspect: 1.0
        )
        vm.selectedPreset = .oneToOne

        // Drag the bottom-right handle out to a non-square rect with the
        // top-left corner anchored — the preset must force it back to 1:1.
        vm.updateRect(
            CGRect(x: 0.0, y: 0.0, width: 0.8, height: 0.4),
            anchor: CGPoint(x: 0.0, y: 0.0)
        )

        XCTAssertEqual(vm.cropRect.width, vm.cropRect.height, accuracy: 1e-9)
    }
}
