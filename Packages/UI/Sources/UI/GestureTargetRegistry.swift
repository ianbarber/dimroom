import SwiftUI

/// Maps a control's wire-name to the on-screen frame (SwiftUI `.global`
/// coordinate space) of the view that bears its gesture. Populated by the
/// `.gestureTarget(key:)` modifier, read by the App's pointer-event
/// synthesizer so a Layer C harness flow can post a real double-click at a
/// slider's track and exercise the gesture chain — not the view-model
/// shortcut (#348).
///
/// Recording is a plain dictionary write on layout, so it stays always-on
/// rather than gated behind a harness flag: the registry is populated in
/// production too, keeping the path the harness drives identical to the one
/// the UI renders (CLAUDE.md hard rule #4). `frames` is intentionally not
/// `@Published` — nothing observes the registry, and a published write
/// during layout would trip SwiftUI's "modifying state during view update"
/// warning.
@MainActor
public final class GestureTargetRegistry {
    public static let shared = GestureTargetRegistry()

    private var frames: [String: CGRect] = [:]

    public init() {}

    /// Record (or overwrite) the global frame for `key`.
    public func record(_ key: String, frame: CGRect) {
        frames[key] = frame
    }

    /// The last-recorded global frame for `key`, or `nil` if no view has
    /// registered under it (control not mounted / off the view tree).
    public func frame(for key: String) -> CGRect? {
        frames[key]
    }

    /// Forget `key`. Not used in the steady state — the modifier keeps the
    /// frame current as layout changes — but handy for tests.
    public func remove(_ key: String) {
        frames[key] = nil
    }

    /// Drop every recorded frame. Test-only.
    public func removeAll() {
        frames.removeAll()
    }
}

public extension View {
    /// Record this view's `.global` frame into ``GestureTargetRegistry/shared``
    /// under `key`, keeping it current as layout changes. Applied to the
    /// inner control whose hit region the harness needs to target. When
    /// `key` is `nil` the modifier is inert, so call sites that have no
    /// wire-name can pass it through unconditionally.
    func gestureTarget(key: String?) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        if let key {
                            GestureTargetRegistry.shared.record(key, frame: proxy.frame(in: .global))
                        }
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                        if let key {
                            GestureTargetRegistry.shared.record(key, frame: newFrame)
                        }
                    }
            }
        )
    }
}
