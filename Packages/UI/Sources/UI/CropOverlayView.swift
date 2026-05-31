import AppKit
import EditEngine
import SwiftUI

/// Interactive crop overlay.
///
/// Given a bound `CropViewModel` whose `cropRect` is in normalised 0…1
/// space, this view draws a darkened exterior, 4 corner + 4 midpoint
/// handles, and a rule-of-thirds grid inside the crop. Drag gestures
/// on handles resize the crop; a drag gesture on the interior
/// translates the crop. Coordinates are mapped through
/// `CropGeometry.pixelToNormalized` so the view-model stays in
/// normalised space.
public struct CropOverlayView: View {
    @ObservedObject var viewModel: CropViewModel
    /// Pixel-space rect captured at the start of an active drag. Set on
    /// the first `.onChanged` event and cleared in `.onEnded`. `body`
    /// re-renders every time `viewModel.cropRect` updates, so without
    /// this the gesture closure would re-capture the already-moved rect
    /// on each frame and apply cumulative translation against a moving
    /// base — making the rect accelerate away from the cursor.
    @State private var dragStartRect: CGRect?
    /// True while any Shift modifier is held. Updated by a local event
    /// monitor; used to promote a `.free`-mode corner drag into a
    /// ratio-locked one (Photoshop/Lightroom convention).
    @State private var shiftHeld: Bool = false
    /// Token returned by `NSEvent.addLocalMonitorForEvents`; retained so
    /// we can remove the monitor on disappear and never leak it.
    @State private var flagMonitor: Any?
    /// `cropAngle` captured on the first `.onChanged` of a rotate drag, so
    /// the swept delta accumulates against a fixed base instead of the
    /// already-rotated value — same reasoning as `dragStartRect`. Non-nil
    /// only while a rotate drag is in flight.
    @State private var dragStartAngle: Double?
    /// The corner currently being rotate-dragged; keeps its curved-arrow
    /// icon lit even if the pointer drifts out of the hover zone mid-drag.
    @State private var activeRotateCorner: RotationCorner?
    /// Live pointer location (overlay space) during a rotate drag; anchors
    /// the floating degree readout. Cleared on `.onEnded`.
    @State private var activeRotateLocation: CGPoint?
    /// The corner the pointer is hovering, which reveals that corner's
    /// rotate affordance. Nil when the pointer is over no rotate zone.
    @State private var hoveredRotationCorner: RotationCorner?

    /// Bypasses `.onHover` to render every rotation handle unconditionally.
    /// Hover events never fire in a headless snapshot, so the Layer B test
    /// uses this to capture the affordance.
    private let forceRotationHandlesVisible: Bool
    /// Sink for live angle changes from a rotate drag. When nil the view
    /// writes straight to `viewModel.setAngle`; `DevelopView` supplies a
    /// closure that routes through `setCropAngleLive` so the preview
    /// re-renders (and debounces) exactly as the straighten slider does.
    private let onAngleChange: ((Double) -> Void)?

    public init(
        viewModel: CropViewModel,
        forceRotationHandlesVisible: Bool = false,
        onAngleChange: ((Double) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.forceRotationHandlesVisible = forceRotationHandlesVisible
        self.onAngleChange = onAngleChange
    }

    // `handleSize`, `rotationHandleOffset`, and `rotationHitSize` are
    // `internal` (not `private`) so the Layer A non-overlap regression
    // test can read them under `@testable import UI` instead of
    // duplicating the magic numbers.
    let handleSize: CGFloat = 12
    private let exteriorFill = Color.black.opacity(0.55)
    private let handleColor = Color.white
    private let gridColor = Color.white.opacity(0.4)
    private let borderColor = Color.white.opacity(0.9)

    /// Euclidean distance from a crop corner to the centre of its rotation
    /// hit-zone, along the 45° diagonal pointing away from the crop. At 34pt
    /// the zone's inner edge clears the `corner ± 6pt` resize handle by ~3pt
    /// (`34/√2 − 30/2 = 9.04pt` vs the handle's 6pt half-width), so the two
    /// hit-zones never compete for the same pixels (#356).
    let rotationHandleOffset: CGFloat = 34
    /// Edge length of a rotation hit-zone (and its icon container).
    let rotationHitSize: CGFloat = 30
    /// Curved-arrow icon point size inside the hit-zone.
    private let rotationIconSize: CGFloat = 15
    /// Named coordinate space so rotate-drag locations resolve against the
    /// overlay (where the crop centre lives) rather than each handle's own
    /// offset frame.
    private let rotationSpace = "cropOverlayRotation"

    public var body: some View {
        GeometryReader { geo in
            let cropPixels = CropGeometry.normalizedToPixel(
                rect: viewModel.cropRect,
                imageSize: geo.size
            )
            let cropCentre = CGPoint(x: cropPixels.midX, y: cropPixels.midY)
            ZStack(alignment: .topLeading) {
                exteriorMask(bounds: geo.size, cropPixels: cropPixels)
                cropBorder(cropPixels: cropPixels)
                ruleOfThirdsGrid(cropPixels: cropPixels)
                translateCatcher(cropPixels: cropPixels, imageSize: geo.size)
                handles(cropPixels: cropPixels, imageSize: geo.size)
                rotationHandles(cropPixels: cropPixels, centre: cropCentre)
                rotationReadout()
            }
            .coordinateSpace(name: rotationSpace)
        }
        .onAppear {
            // Shift-state read via a process-wide local monitor rather
            // than polling `NSEvent.modifierFlags` inside the drag
            // closure, which reads app state and can desync under
            // SwiftUI's gesture coalescing.
            flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                shiftHeld = event.modifierFlags.contains(.shift)
                return event
            }
        }
        .onDisappear {
            if let monitor = flagMonitor {
                NSEvent.removeMonitor(monitor)
                flagMonitor = nil
            }
            shiftHeld = false
        }
    }

    // MARK: - Subviews

    private func exteriorMask(bounds: CGSize, cropPixels: CGRect) -> some View {
        // Even-odd fill: outer rect minus inner crop rect leaves a
        // doughnut shape darkened over the image.
        Path { path in
            path.addRect(CGRect(origin: .zero, size: bounds))
            path.addRect(cropPixels)
        }
        .fill(exteriorFill, style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func cropBorder(cropPixels: CGRect) -> some View {
        Rectangle()
            .stroke(borderColor, lineWidth: 1)
            .frame(width: cropPixels.width, height: cropPixels.height)
            .offset(x: cropPixels.minX, y: cropPixels.minY)
            .allowsHitTesting(false)
    }

    private func ruleOfThirdsGrid(cropPixels: CGRect) -> some View {
        Path { path in
            let thirdW = cropPixels.width / 3
            let thirdH = cropPixels.height / 3
            // Two vertical lines
            for i in 1...2 {
                let x = cropPixels.minX + CGFloat(i) * thirdW
                path.move(to: CGPoint(x: x, y: cropPixels.minY))
                path.addLine(to: CGPoint(x: x, y: cropPixels.maxY))
            }
            // Two horizontal lines
            for i in 1...2 {
                let y = cropPixels.minY + CGFloat(i) * thirdH
                path.move(to: CGPoint(x: cropPixels.minX, y: y))
                path.addLine(to: CGPoint(x: cropPixels.maxX, y: y))
            }
        }
        .stroke(gridColor, lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private func translateCatcher(cropPixels: CGRect, imageSize: CGSize) -> some View {
        // Double-click wins over the drag gesture via `highPriorityGesture`
        // so a quick double-tap doesn't register as a zero-translation
        // drag-to-translate. Normal single-press drags still translate.
        Color.clear
            .contentShape(Rectangle())
            .frame(width: cropPixels.width, height: cropPixels.height)
            .offset(x: cropPixels.minX, y: cropPixels.minY)
            .highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded {
                        viewModel.resetRect()
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartRect ?? cropPixels
                        if dragStartRect == nil { dragStartRect = start }
                        translate(by: value.translation, from: start, imageSize: imageSize)
                    }
                    .onEnded { _ in
                        dragStartRect = nil
                    }
            )
    }

    private func handles(cropPixels: CGRect, imageSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Handle.allCases, id: \.self) { handle in
                let point = handle.position(in: cropPixels)
                handleShape
                    .frame(width: handleSize, height: handleSize)
                    .offset(
                        x: point.x - handleSize / 2,
                        y: point.y - handleSize / 2
                    )
                    .gesture(dragGesture(for: handle, cropPixels: cropPixels, imageSize: imageSize))
            }
        }
    }

    private var handleShape: some View {
        Rectangle()
            .fill(handleColor)
            .overlay(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Rotation handles

    /// Four rotate hit-zones, one just outside each corner. Each is a
    /// transparent square (so the whole zone is draggable) with a
    /// hover-/drag-revealed curved-arrow icon. The zones live in the
    /// darkened exterior beyond the 12pt resize handles, so resizing and
    /// rotating never compete for the same pixels.
    private func rotationHandles(cropPixels: CGRect, centre: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(RotationCorner.allCases, id: \.self) { corner in
                let handleCentre = corner.handleCentre(in: cropPixels, offset: rotationHandleOffset)
                rotationHandle(for: corner)
                    .frame(width: rotationHitSize, height: rotationHitSize)
                    .offset(
                        x: handleCentre.x - rotationHitSize / 2,
                        y: handleCentre.y - rotationHitSize / 2
                    )
                    // Double-click resets the straighten angle, mirroring
                    // the slider's double-click-to-reset. `highPriorityGesture`
                    // beats the drag so a quick double-tap never rotates.
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded { applyAngle(0) }
                    )
                    .gesture(rotationGesture(for: corner, centre: centre))
                    .onHover { inside in
                        if inside {
                            hoveredRotationCorner = corner
                            RotationCursor.shared.push()
                        } else {
                            if hoveredRotationCorner == corner { hoveredRotationCorner = nil }
                            NSCursor.pop()
                        }
                    }
            }
        }
    }

    private func rotationHandle(for corner: RotationCorner) -> some View {
        let visible = forceRotationHandlesVisible
            || hoveredRotationCorner == corner
            || activeRotateCorner == corner
        return ZStack {
            // Transparent catcher so the full zone is draggable even when
            // the icon is hidden.
            Color.clear.contentShape(Rectangle())
            Image(systemName: "arrow.clockwise")
                .font(.system(size: rotationIconSize, weight: .semibold))
                .foregroundStyle(handleColor)
                .rotationEffect(corner.iconRotation)
                .shadow(color: Color.black.opacity(0.7), radius: 1.5)
                .opacity(visible ? 1 : 0)
        }
    }

    /// Floating "+2.4°" readout shown near the pointer during a rotate
    /// drag. Reads `viewModel.cropAngle` so it always reflects the live,
    /// clamped/snapped value the renderer is using.
    @ViewBuilder
    private func rotationReadout() -> some View {
        if let location = activeRotateLocation {
            Text(String(format: "%+.1f°", viewModel.cropAngle))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.65))
                )
                .fixedSize()
                .offset(x: location.x + 14, y: location.y - 28)
                .allowsHitTesting(false)
        }
    }

    private func rotationGesture(for corner: RotationCorner, centre: CGPoint) -> some Gesture {
        // minimumDistance: 1 so a stationary double-click falls through to
        // the reset gesture rather than registering as a 0° rotate drag.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(rotationSpace))
            .onChanged { value in
                let start: Double
                if let dragStartAngle {
                    start = dragStartAngle
                } else {
                    start = viewModel.cropAngle
                    dragStartAngle = start
                    activeRotateCorner = corner
                }
                let delta = CropGeometry.rotationAngle(
                    center: centre,
                    from: value.startLocation,
                    to: value.location
                )
                var newAngle = start + delta
                // Shift snaps the accumulated angle to 15° increments
                // (Lightroom convention).
                if shiftHeld {
                    newAngle = CropGeometry.snapAngle(newAngle, toIncrement: 15)
                }
                activeRotateLocation = value.location
                applyAngle(newAngle)
            }
            .onEnded { _ in
                dragStartAngle = nil
                activeRotateCorner = nil
                activeRotateLocation = nil
            }
    }

    /// Route an angle change through the injected sink (live-render path)
    /// or straight to the view-model when used standalone (e.g. snapshots).
    private func applyAngle(_ angle: Double) {
        if let onAngleChange {
            onAngleChange(angle)
        } else {
            viewModel.setAngle(angle)
        }
    }

    // MARK: - Gesture handling

    private func dragGesture(
        for handle: Handle,
        cropPixels: CGRect,
        imageSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStartRect ?? cropPixels
                if dragStartRect == nil { dragStartRect = start }
                let new = handle.apply(
                    translation: value.translation,
                    to: start
                )
                let anchor = handle.anchor(in: start)
                let anchorNorm = CGPoint(
                    x: anchor.x / imageSize.width,
                    y: anchor.y / imageSize.height
                )
                let normalised = CropGeometry.pixelToNormalized(
                    rect: new,
                    imageSize: imageSize
                )
                // Shift-drag on a corner locks to the rect's current
                // ratio even in `.free` mode — Photoshop/Lightroom
                // convention. Uses the drag-start rect so the ratio
                // doesn't drift mid-gesture as the rect resizes.
                let overrideRatio: Double?
                if handle.isCorner, shiftHeld, viewModel.selectedPreset == .free,
                   start.height > 0 {
                    overrideRatio = Double(start.width / start.height)
                } else {
                    overrideRatio = nil
                }
                viewModel.updateRect(normalised, anchor: anchorNorm, overrideRatio: overrideRatio)
            }
            .onEnded { _ in
                dragStartRect = nil
            }
    }

    private func translate(
        by translation: CGSize,
        from cropPixels: CGRect,
        imageSize: CGSize
    ) {
        let moved = cropPixels.offsetBy(
            dx: translation.width,
            dy: translation.height
        )
        let normalised = CropGeometry.pixelToNormalized(
            rect: moved,
            imageSize: imageSize
        )
        // Translation must never change the rect's shape, so route
        // through `translateRect` (clamp-only) rather than `updateRect`,
        // which would re-apply the active aspect-ratio constraint and
        // teleport the rect when the anchor lands at the midpoint.
        viewModel.translateRect(normalised)
    }
}

// MARK: - Rotation corners

/// The four crop corners that carry a rotate hit-zone. Distinct from
/// `Handle` (which also covers edge midpoints and is resize-only). The
/// raw values match the `corner` argument the harness `dragRotateHandle`
/// command accepts.
enum RotationCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func corner(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Unit diagonal pointing away from the crop centre.
    private var outward: CGSize {
        switch self {
        case .topLeft: return CGSize(width: -1, height: -1)
        case .topRight: return CGSize(width: 1, height: -1)
        case .bottomLeft: return CGSize(width: -1, height: 1)
        case .bottomRight: return CGSize(width: 1, height: 1)
        }
    }

    /// Centre of the rotate hit-zone: `offset` points from the corner along
    /// the outward diagonal (Euclidean distance, hence the √2 split).
    func handleCentre(in rect: CGRect, offset: CGFloat) -> CGPoint {
        let c = corner(in: rect)
        let component = offset / 2.0.squareRoot()
        return CGPoint(
            x: c.x + outward.width * component,
            y: c.y + outward.height * component
        )
    }

    /// Spin the curved-arrow glyph so each corner's icon reads as facing
    /// outward; purely cosmetic.
    var iconRotation: Angle {
        switch self {
        case .bottomRight: return .degrees(0)
        case .bottomLeft: return .degrees(90)
        case .topLeft: return .degrees(180)
        case .topRight: return .degrees(270)
        }
    }
}

// MARK: - Handles

private enum Handle: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    case top, bottom, leading, trailing

    /// True for the 4 corner handles; shift-drag ratio locking only
    /// makes sense on corners (edge handles resize one axis only).
    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return true
        case .top, .bottom, .leading, .trailing:
            return false
        }
    }

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .leading: return CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    /// The anchor corner/edge that must stay fixed while this handle is
    /// being dragged (used for aspect-ratio constraint).
    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .leading: return CGPoint(x: rect.maxX, y: rect.midY)
        case .trailing: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Apply the gesture `translation` to `rect` according to which edge
    /// or corner this handle controls.
    func apply(translation: CGSize, to rect: CGRect) -> CGRect {
        var r = rect
        switch self {
        case .topLeft:
            r.origin.x += translation.width
            r.origin.y += translation.height
            r.size.width -= translation.width
            r.size.height -= translation.height
        case .topRight:
            r.origin.y += translation.height
            r.size.width += translation.width
            r.size.height -= translation.height
        case .bottomLeft:
            r.origin.x += translation.width
            r.size.width -= translation.width
            r.size.height += translation.height
        case .bottomRight:
            r.size.width += translation.width
            r.size.height += translation.height
        case .top:
            r.origin.y += translation.height
            r.size.height -= translation.height
        case .bottom:
            r.size.height += translation.height
        case .leading:
            r.origin.x += translation.width
            r.size.width -= translation.width
        case .trailing:
            r.size.width += translation.width
        }
        // Drag past opposite edge: clamp to zero-width rather than flip.
        if r.size.width < 0 { r.size.width = 0 }
        if r.size.height < 0 { r.size.height = 0 }
        return r
    }
}
