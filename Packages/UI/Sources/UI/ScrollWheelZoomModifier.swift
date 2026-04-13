import AppKit
import SwiftUI

/// `NSViewRepresentable` overlay that intercepts scroll-wheel events
/// when the Option (⌥) modifier is held and forwards them as zoom
/// deltas. Unmodified scroll events pass through to the underlying
/// SwiftUI view.
///
/// The NSView returns `nil` from `hitTest` so it never steals
/// first-responder or gesture recognition from the SwiftUI layer
/// (pinch, drag, double-tap). Instead it installs a local event
/// monitor for `.scrollWheel` events scoped to its window and frame.
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
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitor()
            } else {
                removeMonitor()
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      event.modifierFlags.contains(.option) else {
                    return event
                }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else {
                    return event
                }
                // Positive deltaY = scroll up = zoom in.
                self.onZoom?(event.scrollingDeltaY)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}
