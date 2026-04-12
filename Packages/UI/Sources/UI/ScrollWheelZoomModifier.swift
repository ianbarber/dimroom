import AppKit
import SwiftUI

/// `NSViewRepresentable` overlay that intercepts scroll-wheel events
/// when the Option (⌥) modifier is held and forwards them as zoom
/// deltas. Unmodified scroll events pass through to the underlying
/// SwiftUI view.
///
/// Option is chosen over Cmd to avoid conflict with the macOS
/// accessibility zoom feature bound to Cmd+scroll.
struct ScrollWheelZoomView: NSViewRepresentable {
    /// Called with the scroll Y delta when Option+scroll is detected.
    var onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelInterceptView {
        let view = ScrollWheelInterceptView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ScrollWheelInterceptView, context: Context) {
        nsView.onZoom = onZoom
    }

    final class ScrollWheelInterceptView: NSView {
        var onZoom: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                // Positive deltaY = scroll up = zoom in.
                onZoom?(event.scrollingDeltaY)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}
