import CoreGraphics

/// Pure geometry for translating a SwiftUI `.global` frame into the AppKit
/// window point a synthetic mouse event must target.
///
/// SwiftUI's global space is top-left origin and its `(0,0)` aligns with
/// the top-left of the window's content view (the `NSHostingView` fills the
/// content rect). NSWindow / NSEvent coordinates are bottom-left origin, so
/// the Y axis is flipped against the content-view height. Isolated here,
/// away from the AppKit dispatch path, so the flip math is unit-testable
/// without a window server (#348).
public enum PointerEventGeometry {
    /// The window point (bottom-left origin) to click for a control whose
    /// SwiftUI global frame is `globalFrame`, inside a content view of
    /// height `contentHeight`.
    ///
    /// `fraction` selects the horizontal position along the frame's width
    /// (0 = left edge, 1 = right edge, 0.5 = centre) and is clamped to
    /// `0...1`. The click lands on the frame's vertical midline — for a
    /// slider that is the track centre.
    public static func windowPoint(
        globalFrame: CGRect,
        contentHeight: CGFloat,
        fraction: Double
    ) -> CGPoint {
        let clamped = min(max(fraction, 0), 1)
        let x = globalFrame.minX + CGFloat(clamped) * globalFrame.width
        // SwiftUI top-left Y of the click point → AppKit bottom-left Y.
        let topLeftY = globalFrame.midY
        let y = contentHeight - topLeftY
        return CGPoint(x: x, y: y)
    }
}
