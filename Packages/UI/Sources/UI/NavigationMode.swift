import Foundation

/// Lightweight mirror of `Route` (which lives in the Harness package) so
/// the UI package can display mode labels without depending on Harness.
/// ContentView maps `Route ↔ NavigationMode` at the boundary.
public enum NavigationMode: String, CaseIterable, Sendable {
    case library
    case loupe
    case develop

    public var label: String {
        switch self {
        case .library: "Library"
        case .loupe: "Loupe"
        case .develop: "Develop"
        }
    }

    public var shortcutHint: String {
        switch self {
        case .library: "G"
        case .loupe: "E"
        case .develop: "D"
        }
    }
}
