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
        hitSize: CGFloat,
        handleSize: CGFloat
    ) -> CGRect {
        let centre = corner.handleCentre(
            in: cropPixels,
            offset: offset,
            bounds: bounds,
            hitSize: hitSize,
            handleSize: handleSize
        )
        let half = hitSize / 2
        return CGRect(x: centre.x - half, y: centre.y - half, width: hitSize, height: hitSize)
    }

    func test_full_frame_crop_keeps_every_rotate_zone_in_bounds() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        let handleSize = overlay.handleSize
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
                hitSize: hitSize,
                handleSize: handleSize
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
        let handleSize = overlay.handleSize
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
                hitSize: hitSize,
                handleSize: handleSize
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
        let handleSize = overlay.handleSize
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
                hitSize: hitSize,
                handleSize: handleSize
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
            hitSize: hitSize,
            handleSize: overlay.handleSize
        )
        XCTAssertEqual(centre.x, bounds.width / 2, accuracy: 0.001)
    }

    /// #406: the headline bug. With the crop full-frame, each corner sits on
    /// the image edge, so #389's bounds clamp pulls the rotate zone inward
    /// until it sits *over* that corner's 12pt resize handle. Pre-fix the
    /// `[0,30]²` zone fully contained the in-bounds `[0,6]²` resize footprint
    /// and — being drawn later — stole its hit testing. The clearance nudge
    /// must leave the resize footprint reachable: the zone no longer contains
    /// it (in fact only corner-touches it), while staying inside the overlay.
    func test_full_frame_corner_resize_handle_not_fully_occluded_by_rotate_zone() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        let handleSize = overlay.handleSize
        let bounds = CGSize(width: 640, height: 480)
        let cropPixels = CGRect(origin: .zero, size: bounds)
        let frame = CGRect(origin: .zero, size: bounds)
        for corner in RotationCorner.allCases {
            let rotateZone = hitRect(
                for: corner,
                cropPixels: cropPixels,
                offset: offset,
                bounds: bounds,
                hitSize: hitSize,
                handleSize: handleSize
            )
            // The reachable part of the corner's resize handle: the 12pt
            // square centred on the corner, clipped to the overlay.
            let cornerPoint = corner.corner(in: cropPixels)
            let half = handleSize / 2
            let resizeHandle = CGRect(
                x: cornerPoint.x - half,
                y: cornerPoint.y - half,
                width: handleSize,
                height: handleSize
            ).intersection(frame)
            XCTAssertFalse(
                rotateZone.contains(resizeHandle),
                "\(corner) resize handle \(resizeHandle) fully occluded by rotate zone \(rotateZone)"
            )
            // The clearance never pushes the zone back off-frame (#389).
            XCTAssertTrue(
                frame.contains(rotateZone),
                "\(corner) rotate zone \(rotateZone) left the overlay \(frame)"
            )
        }
    }

    /// A corner pinned to two edges at once (crop in the top-left, inset on
    /// the right and bottom) drives the both-axes-clamped clearance path on a
    /// non-full-frame rect. The topLeft corner's resize handle must stay
    /// reachable just as in the full-frame case.
    func test_two_adjacent_edge_corner_resize_handle_reachable() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize
        let handleSize = overlay.handleSize
        let bounds = CGSize(width: 640, height: 480)
        let cropPixels = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = CGRect(origin: .zero, size: bounds)
        let rotateZone = hitRect(
            for: .topLeft,
            cropPixels: cropPixels,
            offset: offset,
            bounds: bounds,
            hitSize: hitSize,
            handleSize: handleSize
        )
        let half = handleSize / 2
        let resizeHandle = CGRect(
            x: -half, y: -half, width: handleSize, height: handleSize
        ).intersection(frame)
        XCTAssertFalse(
            rotateZone.contains(resizeHandle),
            "topLeft resize handle \(resizeHandle) fully occluded by rotate zone \(rotateZone)"
        )
        XCTAssertTrue(
            frame.contains(rotateZone),
            "topLeft rotate zone \(rotateZone) left the overlay \(frame)"
        )
    }

    /// An axis only a little wider than the hit-zone can't absorb the full
    /// `handleSize/2` clearance, so the nudge is re-clamped — the zone must
    /// still end up wholly inside the overlay (#389 wins over the #406 nudge).
    func test_clearance_reclamped_into_bounds_on_small_axis() {
        let overlay = makeOverlay()
        let offset = overlay.rotationHandleOffset
        let hitSize = overlay.rotationHitSize        // 30
        let handleSize = overlay.handleSize          // 12
        // width 35: half = 15, axisLength − half = 20. The low-edge clearance
        // target 15 + 6 = 21 exceeds 20, so it re-clamps to 20; the zone then
        // spans exactly [5, 35] — still inside the axis.
        let bounds = CGSize(width: 35, height: 480)
        let cropPixels = CGRect(origin: .zero, size: bounds)
        let centre = RotationCorner.topLeft.handleCentre(
            in: cropPixels,
            offset: offset,
            bounds: bounds,
            hitSize: hitSize,
            handleSize: handleSize
        )
        XCTAssertEqual(centre.x, bounds.width - hitSize / 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(centre.x - hitSize / 2, 0)
        XCTAssertLessThanOrEqual(centre.x + hitSize / 2, bounds.width)
    }
}
