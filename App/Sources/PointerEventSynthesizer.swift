import AppKit

/// Posts a synthetic left-button double-click so SwiftUI's gesture
/// recognisers see a real event sequence rather than a direct view-model
/// call. Built for the harness `doubleClickSlider` command to exercise the
/// Develop slider reset gesture
/// (`highPriorityGesture(TapGesture(count: 2))`) end-to-end — the path
/// #265/#347 fixed and that no other Layer C command touches.
///
/// ⚠️ KNOWN LIMITATION — does not yet work in the headless harness (#348).
/// Two facts, both confirmed empirically against the running app:
///
/// 1. SwiftUI controls ignore programmatically-built `NSEvent`s
///    (`NSEvent.mouseEvent(...)` / `NSEvent(cgEvent:)`), whether delivered
///    via `window.sendEvent`, `NSApp.sendEvent`, or `NSApp.postEvent`. The
///    slider value never moves. They have no real `CGEvent` backing /
///    window routing that SwiftUI's hit-testing honours.
/// 2. Real `CGEvent` injection (below) goes through the OS event pipeline,
///    but is silently dropped unless the posting process is
///    Accessibility-trusted (`AXIsProcessTrusted()`). The harness runs as
///    an unsigned SPM executable, so trust is `false` — and CI runners
///    won't grant it to an unsigned binary either.
///
/// The coordinate math (`PointerEventGeometry` + the window→screen→Quartz
/// hop here) is correct — verified the computed point lands on the target
/// slider. The blocker is event *delivery*, not geometry. Resolving it
/// needs an environment decision (a signed/bundled app with a TCC grant,
/// or a different gesture-driving mechanism) — see the issue #348 thread.
enum PointerEventSynthesizer {
    /// Post a left-button double-click at `windowPoint` (window base
    /// coordinates, bottom-left origin) on `window`. Emits two down/up
    /// pairs, raising the click-state to 2 on the second pair so a
    /// `TapGesture(count: 2)` recogniser fires. The caller should yield to
    /// the run loop afterwards (e.g. `await Task.sleep`) so the events are
    /// processed before reading back state.
    @MainActor
    static func doubleClick(at windowPoint: CGPoint, in window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let quartzPoint = quartzGlobalPoint(from: windowPoint, in: window) else { return }
        let source = CGEventSource(stateID: .hidSystemState)

        post(.mouseMoved, at: quartzPoint, clickState: 0, source: source)
        post(.leftMouseDown, at: quartzPoint, clickState: 1, source: source)
        post(.leftMouseUp, at: quartzPoint, clickState: 1, source: source)
        post(.leftMouseDown, at: quartzPoint, clickState: 2, source: source)
        post(.leftMouseUp, at: quartzPoint, clickState: 2, source: source)
    }

    private static func post(
        _ type: CGEventType,
        at point: CGPoint,
        clickState: Int64,
        source: CGEventSource?
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Convert a window-base point (bottom-left origin) into the Quartz
    /// global display coordinates (top-left origin) that `CGEvent` expects.
    /// Assumes the window sits on the primary display — true for the
    /// harness window and CI's single virtual display.
    @MainActor
    private static func quartzGlobalPoint(from windowPoint: CGPoint, in window: NSWindow) -> CGPoint? {
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        guard let primary else { return nil }
        return CGPoint(x: screenPoint.x, y: primary.frame.height - screenPoint.y)
    }
}
