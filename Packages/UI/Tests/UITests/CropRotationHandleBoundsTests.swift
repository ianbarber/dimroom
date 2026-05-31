import XCTest

@testable import UI

/// Layer A regression tests for #389: a rotate hit-zone whose corner sits
/// on the image edge must stay inside the overlay bounds so it remains
/// grabbable, instead of being pushed off-frame along the outward diagonal.
///
/// These exercise the pure geometry in `RotationCorner.handleCentre`,
/// which clamps each zone's centre so the full `rotationHitSize` square is
/// contained in the overlay. They complement `CropRotationHitZoneTests`
/// (rotate-vs-resize spacing) without rendering.
@MainActor
final class CropRotationHandleBoundsTests: XCTestCase {
    /// Build the overlay only to read its published `rotationHandleOffset`
    /// / `rotationHitSize` constants — the geometry under test lives on
    /// `RotationCorner`, not the rendered view (same pattern as
    /// `CropRotationHitZoneTests`).
    private func makeOverlay() -> CropOverlayView {
        CropOverlayView(viewModel: CropViewModel())
    }

    /// The rotate hit-zone rect for a corner, reconstructed the way `body`
    /// does: centre from `handleCentre`, size `hitSize`.
    private func hitRect(
        for corner: RotationCorner,
        cropPixels: CGRect,
        offset: CGFloat,
        bounds: CGSize,
        hitSize: CGFloat
    ) -> CGRect {
        let centre = corner.handleCentre(
            in: cropPixels,
            offset: offset,
            bounds: bounds,
            hitSize: hitSize
        )
        let half = hitSize / 2
        return CGRect(x: centre.x - half, y: centre.y - half, width: hitSize, height: hitSize)
    }

    func test_full_frame_crop_keeps_every_rotate_zone_in_bounds() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        let bounds = CGSize(width: 640, height: 480)
        // Crop fills the whole image: all four corners are on the edge.
        let cropPixels = CGRect(origin: .zero, size: bounds)
        let frame = CGRect(origin: .zero, size: bounds)
        for corner in RotationCorner.allCases {
            let rect = hitRect(
                for: corner,
                cropPixels: cropPixels,
                offset: offset,
                bounds: bounds,
                hitSize: hitSize
            )
            XCTAssertTrue(
                frame.contains(rect),
                "\(corner) rotate zone \(rect) falls outside overlay \(frame)"
            )
        }
    }

    func test_top_edge_crop_keeps_top_zones_in_bounds_but_still_outward() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        let bounds = CGSize(width: 640, height: 480)
        // Touches only the top edge (y = 0), inset on the other three.
        let cropPixels = CGRect(x: 120, y: 0, width: 400, height: 300)
        let frame = CGRect(origin: .zero, size: bounds)
        let component = offset / 2.0.squareRoot()
        for corner in [RotationCorner.topLeft, .topRight] {
            let rect = hitRect(
                for: corner,
                cropPixels: cropPixels,
                offset: offset,
                bounds: bounds,
                hitSize: hitSize
            )
            XCTAssertTrue(
                frame.contains(rect),
                "\(corner) top-edge rotate zone \(rect) falls outside overlay \(frame)"
            )
            // The y was clamped inward (the corner is on the edge), but the
            // horizontal axis has room, so x keeps its full outward offset.
            let cornerPoint = corner.corner(in: cropPixels)
            let centreX = rect.midX
            XCTAssertEqual(
                abs(centreX - cornerPoint.x),
                component,
                accuracy: 0.001,
                "\(corner) lost its outward x offset where the axis had room"
            )
            XCTAssertGreaterThanOrEqual(
                rect.minY,
                0,
                "\(corner) y not clamped into bounds"
            )
        }
    }

    func test_inset_crop_clamp_is_a_no_op() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        let bounds = CGSize(width: 640, height: 480)
        // An inset crop (matches the kind the existing goldens use); the
        // clamp must not move these zones or it would shift the goldens.
        let cropPixels = CGRect(x: 96, y: 72, width: 448, height: 336)
        let component = offset / 2.0.squareRoot()
        for corner in RotationCorner.allCases {
            let clamped = corner.handleCentre(
                in: cropPixels,
                offset: offset,
                bounds: bounds,
                hitSize: hitSize
            )
            let cornerPoint = corner.corner(in: cropPixels)
            let outwardX: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? -component : component
            let outwardY: CGFloat = (corner == .topLeft || corner == .topRight) ? -component : component
            XCTAssertEqual(clamped.x, cornerPoint.x + outwardX, accuracy: 0.001, "\(corner) x moved by clamp on inset crop")
            XCTAssertEqual(clamped.y, cornerPoint.y + outwardY, accuracy: 0.001, "\(corner) y moved by clamp on inset crop")
        }
    }

    func test_axis_narrower_than_hit_zone_centres_on_midpoint() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        // Degenerate overlay narrower than the hit-zone on the x axis: the
        // zone can't fit, so it centres on the axis midpoint rather than
        // producing an inverted clamp range.
        let bounds = CGSize(width: 20, height: 480)
        let cropPixels = CGRect(origin: .zero, size: bounds)
        let centre = RotationCorner.topLeft.handleCentre(
            in: cropPixels,
            offset: offset,
            bounds: bounds,
            hitSize: hitSize
        )
        XCTAssertEqual(centre.x, bounds.width / 2, accuracy: 0.001)
    }
}
