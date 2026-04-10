import Foundation

/// Snapshot of the app's current state, returned by the `state` command.
public struct AppState: Codable, Sendable, Equatable {
    public let route: Route

    public init(route: Route) {
        self.route = route
    }
}
