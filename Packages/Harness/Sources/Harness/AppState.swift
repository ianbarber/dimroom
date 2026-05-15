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
    /// Active import-session scope. `nil` means "All Photos" or
    /// "Recently Deleted" (distinguished by `scopeKind`).
    public let scopeSessionId: UUID?
    /// Which scope kind is active: `all`, `session` (pair with
    /// `scopeSessionId`), or `recentlyDeleted`. Harness flows assert on
    /// this to verify trash scope transitions.
    public let scopeKind: String
    /// Every asset id currently included in the library multi-selection.
    /// When nothing is selected this is empty. `selectedAssetId` is the
    /// most-recently-clicked id inside this set.
    public let selectedAssetIds: [UUID]
    /// Whether the loupe is currently zoomed beyond fit-to-window.
    public let isZoomed: Bool
    /// True while the undo toast is on screen. Harness flows use this to
    /// verify a soft-delete surfaced the toast without having to look
    /// inside the screenshot.
    public let hasUndoToast: Bool
    /// Asset ids whose original is being fetched right now. Mirrors
    /// `LibraryViewModel.downloadingAssetIds` so harness flows can poll
    /// for the in-flight set without scraping the screenshot.
    public let downloadingAssetIds: [UUID]
    /// Per-asset download progress in `[0, 1]`. Keys are UUID strings so
    /// JSON consumers can index by asset id (Swift's JSONEncoder rejects
    /// non-string dictionary keys, and `data.downloadProgressByAssetId.<uuid>`
    /// is a much friendlier wire shape than a parallel array).
    public let downloadProgressByAssetId: [String: Double]
    /// Whether the Develop histogram overlay is currently visible.
    /// Mirrors `DevelopViewModel.showHistogram` so harness flows can
    /// assert the `toggleHistogram` command flipped it. Defaults to
    /// `true` to match the view model's startup state.
    public let showHistogram: Bool
    /// Whether Develop is currently fetching an original for its active
    /// asset. Mirrors `DevelopViewModel.isDownloadingOriginal` so harness
    /// flows can assert the mid-fetch overlay clears immediately on
    /// asset switch (the regression #204 fixed).
    public let developIsDownloadingOriginal: Bool
    /// Develop's current download progress in `[0, 1]`, or `nil` when no
    /// fetch is in flight. Mirrors `DevelopViewModel.downloadProgress`.
    public let developDownloadProgress: Double?
    /// Asset currently active in `DevelopViewModel`, or `nil` if no
    /// asset has been activated yet. Distinct from `selectedAssetId`
    /// (which is Library's selection) because Develop activations can
    /// happen via auto-activate paths (`setEditParameter`, `setCrop`)
    /// that don't touch Library state.
    public let developCurrentAssetId: UUID?

    public init(
        route: Route,
        assetCount: Int = 0,
        selectedAssetId: UUID? = nil,
        minRating: Int = 0,
        scopeSessionId: UUID? = nil,
        scopeKind: String = "all",
        selectedAssetIds: [UUID] = [],
        isZoomed: Bool = false,
        hasUndoToast: Bool = false,
        downloadingAssetIds: [UUID] = [],
        downloadProgressByAssetId: [String: Double] = [:],
        showHistogram: Bool = true,
        developIsDownloadingOriginal: Bool = false,
        developDownloadProgress: Double? = nil,
        developCurrentAssetId: UUID? = nil
    ) {
        self.route = route
        self.assetCount = assetCount
        self.selectedAssetId = selectedAssetId
        self.minRating = minRating
        self.scopeSessionId = scopeSessionId
        self.scopeKind = scopeKind
        self.selectedAssetIds = selectedAssetIds
        self.isZoomed = isZoomed
        self.hasUndoToast = hasUndoToast
        self.downloadingAssetIds = downloadingAssetIds
        self.downloadProgressByAssetId = downloadProgressByAssetId
        self.showHistogram = showHistogram
        self.developIsDownloadingOriginal = developIsDownloadingOriginal
        self.developDownloadProgress = developDownloadProgress
        self.developCurrentAssetId = developCurrentAssetId
    }
}
