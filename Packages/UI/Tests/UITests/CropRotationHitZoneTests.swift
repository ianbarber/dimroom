import CoreGraphics
@testable import UI
import XCTest

/// Regression guard for #356: the drag-to-rotate hit-zone added in #323
/// must not overlap the corner resize handle. At `rotationHandleOffset = 22`
/// the zone's inner edge landed ~0.56pt outside the corner while the resize
/// handle reaches `corner + 6pt`, leaving a ~5.44pt overlap square (~21% of
/// the handle) where the later-drawn transparent rotate catcher stole hit
/// testing. Bumping the offset to 34 opens a clean ~3pt gap.
///
/// These assertions read the geometry constants straight off
/// `CropOverlayView` (now `internal`, hence `@testable import UI`) so the
/// magic numbers live in exactly one place and the test fails the moment
/// someone shrinks the offset back into the overlap regime.
final class CropRotationHitZoneTests: XCTestCase {

    /// A sample crop rect in pixel space, away from any image edge so the
    /// zone geometry is unclipped. The absolute origin is irrelevant — the
    /// rotate-zone/resize-handle relationship is purely offset-driven.
    private let sampleRect = CGRect(x: 100, y: 80, width: 300, height: 200)

    /// Build the square hit/handle rect a corner draws, centred on `point`.
    private func square(centredAt point: CGPoint, size: CGFloat) -> CGRect {
        CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )
    }

    /// The rotate hit-zone and the resize handle for every corner must be
    /// fully disjoint — `CGRect.intersects` is false even for edge-touching
    /// rects, so this is the strict non-overlap check the issue asks for.
    @MainActor
    func testRotateZoneDoesNotOverlapResizeHandle() {
        let overlay = CropOverlayView(viewModel: CropViewModel())

        for corner in RotationCorner.allCases {
            let rotateZone = square(
                centredAt: corner.handleCentre(
                    in: sampleRect,
                    offset: overlay.rotationHandleOffset
                ),
                size: overlay.rotationHitSize
            )
            let resizeHandle = square(
                centredAt: corner.corner(in: sampleRect),
                size: overlay.handleSize
            )

            XCTAssertFalse(
                rotateZone.intersects(resizeHandle),
                "Rotate zone overlaps the resize handle at \(corner) — "
                    + "rotationHandleOffset (\(overlay.rotationHandleOffset)) "
                    + "is too small."
            )
        }
    }

    /// Beyond merely not touching, the fix promises a "clean gap." Expanding
    /// the resize handle outward by 2pt on every side must still leave it
    /// clear of the rotate zone, locking in at least ~2pt of breathing room
    /// (the actual diagonal-axis gap at offset 34 is ~3pt).
    @MainActor
    func testRotateZoneKeepsCleanGapFromResizeHandle() {
        let overlay = CropOverlayView(viewModel: CropViewModel())
        let minGap: CGFloat = 2

        for corner in RotationCorner.allCases {
            let rotateZone = square(
                centredAt: corner.handleCentre(
                    in: sampleRect,
                    offset: overlay.rotationHandleOffset
                ),
                size: overlay.rotationHitSize
            )
            let expandedHandle = square(
                centredAt: corner.corner(in: sampleRect),
                size: overlay.handleSize
            ).insetBy(dx: -minGap, dy: -minGap)

            XCTAssertFalse(
                rotateZone.intersects(expandedHandle),
                "Rotate zone is within \(minGap)pt of the resize handle at "
                    + "\(corner) — gap is too tight to be a clean separation."
            )
        }
    }
}
