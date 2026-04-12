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
    /// Active minimum-rating filter. `0` means "show everything" — any
    /// other value restricts the library grid to assets where
    /// `rating >= minRating`. Harness flows check this to prove that
    /// `setFilter` actually reached the view model.
    public let minRating: Int
    /// Active import-session scope. `nil` means "All Photos".
    public let scopeSessionId: UUID?

    public init(
        route: Route,
        assetCount: Int = 0,
        selectedAssetId: UUID? = nil,
        minRating: Int = 0,
        scopeSessionId: UUID? = nil
    ) {
        self.route = route
        self.assetCount = assetCount
        self.selectedAssetId = selectedAssetId
        self.minRating = minRating
        self.scopeSessionId = scopeSessionId
    }
}
