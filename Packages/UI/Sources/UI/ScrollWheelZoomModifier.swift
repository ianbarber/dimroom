import AppKit
import SwiftUI

/// `NSViewRepresentable` overlay that intercepts trackpad / scroll-wheel
/// events in the Loupe. Two behaviours:
///
/// - **Option (⌥) held:** forwards the Y delta as a zoom delta via `onZoom`.
/// - **No modifiers:** forwards X/Y deltas as a pan translation via `onPan`.
///
/// Cmd-scroll is left untouched so the macOS accessibility zoom keeps
/// working. Any other modifier combination also passes through.
///
/// The NSView returns `nil` from `hitTest` so it never steals
/// first-responder or gesture recognition from the SwiftUI layer
/// (pinch, drag, double-tap). Instead it installs a local event
/// monitor for `.scrollWheel` events scoped to its window and frame.
struct ScrollWheelZoomView: NSViewRepresentable {
    /// Called with the scroll Y delta when Option+scroll is detected.
    var onZoom: (CGFloat) -> Void
    /// Called with the (X, Y) scroll delta for unmodified two-finger
    /// scroll. Returns `true` if the pan was applied (event is consumed)
    /// and `false` if it was ignored (e.g. at fit scale). When `false`,
    /// the event is passed through so underlying SwiftUI scroll consumers
    /// aren't blocked.
    var onPan: (CGFloat, CGFloat) -> Bool

    func makeNSView(context: Context) -> ScrollWheelInterceptView {
        let view = ScrollWheelInterceptView()
        view.onZoom = onZoom
        view.onPan = onPan
        return view
    }

    func updateNSView(_ nsView: ScrollWheelInterceptView, context: Context) {
        nsView.onZoom = onZoom
        nsView.onPan = onPan
    }

    final class ScrollWheelInterceptView: NSView {
        var onZoom: ((CGFloat) -> Void)?
        var onPan: ((CGFloat, CGFloat) -> Bool)?
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
                      event.window === window else {
                    return event
                }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView) else {
                    return event
                }

                // Cmd-scroll is reserved for the macOS accessibility zoom.
                if event.modifierFlags.contains(.command) {
                    return event
                }

                if event.modifierFlags.contains(.option) {
                    // Positive deltaY = scroll up = zoom in.
                    self.onZoom?(event.scrollingDeltaY)
                    return nil
                }

                // Plain two-finger scroll → pan. If the callee didn't
                // consume it (e.g. at fit scale), let the event pass
                // through so underlying scroll consumers still work.
                let consumed = self.onPan?(event.scrollingDeltaX, event.scrollingDeltaY) ?? false
                return consumed ? nil : event
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
