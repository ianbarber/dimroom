import Foundation

/// Snapshot of the app's current state, returned by the `state` command.
public struct AppState: Codable, Sendable, Equatable {
    public let route: Route
    /// Number of non-deleted assets currently visible in the library view
    /// model. Harness flows use this to confirm imports reached the UI.
    public let assetCount: Int
    /// Identifier of the asset currently selected in the library grid, or
    /// `nil` when nothing is selected.
    public let selectedAssetId: UUID?

    public init(
        route: Route,
        assetCount: Int = 0,
        selectedAssetId: UUID? = nil
    ) {
        self.route = route
        self.assetCount = assetCount
        self.selectedAssetId = selectedAssetId
    }
}
