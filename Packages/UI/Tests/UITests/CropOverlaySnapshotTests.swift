import AppKit
import CoreGraphics
import Foundation
import SnapshotTesting
import SwiftUI
@testable import UI
import XCTest

final class CropOverlaySnapshotTests: XCTestCase {
    private static let snapshotRecordMode: SnapshotTestingConfiguration.Record? = {
        if ProcessInfo.processInfo.environment["DIMROOM_RECORD_SNAPSHOTS"] == "1" {
            return .all
        }
        return nil
    }()

    private func runAssertSnapshot(_ body: () -> Void) {
        if let recordMode = Self.snapshotRecordMode {
            withSnapshotTesting(record: recordMode) {
                body()
            }
        } else {
            body()
        }
    }

    private static let frameSize = CGSize(width: 640, height: 480)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    @MainActor
    private func renderFixedPixelImage(
        for view: some View,
        size: CGSize = CropOverlaySnapshotTests.frameSize
    ) -> NSImage {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            fatalError("Failed to allocate NSBitmapImageRep for snapshot")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Render the overlay on top of a flat coloured background so the
    /// darkened exterior, handles, and rule-of-thirds grid are all
    /// clearly visible in the snapshot.
    @MainActor
    private func overlayOnBackdrop(
        viewModel: CropViewModel,
        forceRotationHandlesVisible: Bool = false
    ) -> some View {
        ZStack {
            Color(red: 0.3, green: 0.45, blue: 0.6)
            CropOverlayView(
                viewModel: viewModel,
                forceRotationHandlesVisible: forceRotationHandlesVisible
            )
        }
        .frame(
            width: CropOverlaySnapshotTests.frameSize.width,
            height: CropOverlaySnapshotTests.frameSize.height
        )
    }

    // MARK: - Snapshots

    /// Centre 3:2 crop — verifies handles, rule-of-thirds grid, and
    /// darkened exterior all render in expected positions.
    @MainActor
    func test_crop_overlay_centre_3to2() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.125, y: 0.0, width: 0.75, height: 1.0),
            angle: 0,
            imageAspect: 4.0 / 3.0
        )
        vm.selectedPreset = .threeToTwo

        let image = renderFixedPixelImage(for: overlayOnBackdrop(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    /// Regression for #156 Bug 2: re-entering crop mode on an asset
    /// that already has a crop must show the full frame with the
    /// stored crop rectangle overlaid — not a full-bleed rect on the
    /// cropped-out preview. Stored crop is 0.1…0.9, so the snapshot
    /// should show an inner 80% region with 10% darkened margins on
    /// every side.
    @MainActor
    func test_crop_overlay_shows_full_frame_with_existing_crop_overlaid() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            angle: 0,
            imageAspect: 4.0 / 3.0
        )

        let image = renderFixedPixelImage(for: overlayOnBackdrop(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    /// Rotation handles revealed at all four corners. Hover events don't
    /// fire in a headless render, so `forceRotationHandlesVisible` lights
    /// the curved-arrow affordances unconditionally. Verifies they sit
    /// just outside each corner, clear of the resize handles.
    @MainActor
    func test_crop_overlay_rotation_handles_visible() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7),
            angle: 0,
            imageAspect: 4.0 / 3.0
        )

        let image = renderFixedPixelImage(
            for: overlayOnBackdrop(viewModel: vm, forceRotationHandlesVisible: true)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    /// #389: a full-frame crop puts every corner on the image edge, where
    /// the outward rotate offset would push the affordance off-frame. The
    /// clamp pulls each zone just inside the boundary, so all four
    /// curved-arrow affordances render fully within the frame near their
    /// corners (rather than being clipped at the edges).
    @MainActor
    func test_crop_overlay_rotation_handles_full_frame_clamped_inward() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            angle: 0,
            imageAspect: 4.0 / 3.0
        )

        let image = renderFixedPixelImage(
            for: overlayOnBackdrop(viewModel: vm, forceRotationHandlesVisible: true)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    /// 1:1 crop centred with a +10° straighten angle. This snapshot
    /// doesn't rotate the overlay itself (rotation happens in the
    /// renderer) — it exists to ensure the overlay stays axis-aligned
    /// regardless of `cropAngle`.
    @MainActor
    func test_crop_overlay_square_with_angle() {
        let vm = CropViewModel()
        vm.activate(
            cropRect: CGRect(x: 0.25, y: 0.16, width: 0.5, height: 0.68),
            angle: 10,
            imageAspect: 1.0
        )
        vm.selectedPreset = .oneToOne

        let image = renderFixedPixelImage(for: overlayOnBackdrop(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }
}
