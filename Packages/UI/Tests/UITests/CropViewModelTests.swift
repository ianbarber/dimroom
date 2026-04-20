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

    // MARK: - setAngle

    /// Regression for #137: a near-edge crop rotated by 30° must be
    /// shrunk so all corners stay within the inscribed rectangle of the
    /// rotated unit square.
    @MainActor
    func testSetAngleShrinksNearEdgeCropToStayInsideRotatedBounds() {
        let vm = CropViewModel()
        // Near-edge (only 0.15 clearance on each side) and large enough
        // that the 30° rotated projection exceeds the unit square.
        let initial = CGRect(x: 0.15, y: 0.15, width: 0.8, height: 0.8)
        vm.activate(cropRect: initial, angle: 0, imageAspect: 1.0)

        vm.setAngle(30)

        XCTAssertEqual(vm.cropAngle, 30, accuracy: 1e-9)
        XCTAssertLessThan(vm.cropRect.width, initial.width)
        XCTAssertLessThan(vm.cropRect.height, initial.height)

        // Centre is preserved — helper's documented contract.
        XCTAssertEqual(vm.cropRect.midX, initial.midX, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.midY, initial.midY, accuracy: 1e-9)

        // Projection onto the rotated axes must fit within the unit
        // square.
        let theta = 30.0 * .pi / 180.0
        let cosT = Foundation.cos(theta)
        let sinT = Foundation.sin(theta)
        let w = vm.cropRect.width
        let h = vm.cropRect.height
        let epsilon = 1e-9
        XCTAssertLessThanOrEqual(w * cosT + h * sinT, 1.0 + epsilon)
        XCTAssertLessThanOrEqual(w * sinT + h * cosT, 1.0 + epsilon)
    }

    /// A small centred crop already fits inside the rotated bounds and
    /// must not be shrunk — guards against over-eager fitting.
    @MainActor
    func testSetAngleLeavesSmallCentredCropUnchanged() {
        let vm = CropViewModel()
        let initial = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        vm.activate(cropRect: initial, angle: 0, imageAspect: 1.0)

        vm.setAngle(30)

        XCTAssertEqual(vm.cropAngle, 30, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.origin.x, initial.origin.x, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.origin.y, initial.origin.y, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.width, initial.width, accuracy: 1e-9)
        XCTAssertEqual(vm.cropRect.height, initial.height, accuracy: 1e-9)
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
