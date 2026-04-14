import Catalog
import Combine
import Foundation
import Previews

/// Drives the library grid. Holds the sorted, filtered list of assets the
/// grid displays plus the current single-selection. Construct with
/// injected `CatalogDatabase` and `PreviewStore`; no globals.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public private(set) var rows: [LibraryRow] = []
    @Published public var selectedAssetId: UUID?
    /// Minimum rating currently required for a row to appear in `rows`.
    /// `0` (the default) means "show everything". Any other value in
    /// `1...5` hides rows whose asset has a lower rating. Mutating this
    /// directly does **not** trigger a reload — callers should go through
    /// `setMinRating(_:)` so the grid is re-queried.
    @Published public private(set) var minRating: Int = 0
    /// Currently active import-session scope. `nil` means "All Photos".
    @Published public private(set) var scopeSessionId: UUID?
    /// Recent import sessions for the scope picker.
    @Published public private(set) var recentSessions: [ImportSessionSummary] = []
    /// Monotonic counter bumped on every successful rotate. Views that
    /// cache decoded NSImages keyed on the file path (Loupe, Cell) apply
    /// `.id(rowVersion)` to their image subtree so SwiftUI forces a
    /// rebuild the instant `R` is pressed and the JPEG on disk is
    /// rewritten — otherwise `NSImage(contentsOf:)` serves the stale
    /// CGImage it decoded the first time around.
    @Published public private(set) var rowVersion: Int = 0

    /// Brief toast feedback when a rating is set. Views observe this to
    /// show a transient star count overlay. Cleared automatically after
    /// a short delay by the toast view.
    @Published public var ratingToast: RatingToast?

    /// Trigger property for zoom commands. ContentView sets this when
    /// the user presses Z or Cmd+0; LoupeView observes it via
    /// `.onChange`, executes the zoom action with its local state, and
    /// clears it back to `nil`.
    @Published public var pendingZoomCommand: ZoomCommand?

    /// Whether the loupe is currently zoomed beyond fit-to-window.
    /// LoupeView writes this after every zoom mutation so the harness
    /// can assert zoom state without inspecting screenshots.
    @Published public var isZoomed: Bool = false

    /// Asset ids for which an original-fetch is currently in flight.
    /// The Loupe overlay observes this to show a download indicator;
    /// entries land here when `fetchOriginalIfNeeded(assetId:)` kicks
    /// off and are removed when the task resolves.
    @Published public private(set) var downloadingAssetIds: Set<UUID> = []

    /// App-level coordinator that returns a local URL for an original,
    /// downloading it from Drive if needed. `nil` in tests and the
    /// empty placeholder view model so the view degrades to preview-only.
    public var originalFetcher: (any OriginalFetcher)?

    /// Lightweight value published when a rating changes so the UI can
    /// show brief visual feedback.
    public struct RatingToast: Equatable {
        public let assetId: UUID
        public let rating: Int
    }

    /// Zoom actions that ContentView can request LoupeView to perform.
    public enum ZoomCommand: Equatable {
        case toggleFitTo100
        case resetToFit
    }

    /// Number of columns in the library grid. Shared between `LibraryView`
    /// (layout) and navigation (Up/Down arrow skip by this count).
    public static let columnCount = 4

    private var catalog: CatalogDatabase
    private var previewStore: PreviewStore
    private var reloadTask: Task<Void, Never>?

    public init(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    /// Swap the backing catalog and preview store, then reload. Used by
    /// `AppDelegate.applicationDidFinishLaunching` to upgrade the
    /// placeholder in-memory catalog to the real one while keeping the
    /// same object identity that the SwiftUI view tree is already
    /// observing.
    public func configure(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
        reload()
    }

    /// Reload non-deleted assets from the catalog, sort them newest-first,
    /// and resolve their thumbnail URLs. The catalog read happens on a
    /// background task so the main thread never blocks on SQLite; the
    /// result is published on `MainActor`. If the selected asset
    /// disappears on reload, selection is cleared.
    ///
    /// Synchronous for test ergonomics: tests can call `reload()` and
    /// inspect `rows` on the next `await` without an expectation dance.
    /// In production the cost is one Task hop, which is negligible.
    public func reload() {
        reloadTask?.cancel()
        let catalog = self.catalog
        let previewStore = self.previewStore
        let minRating = self.minRating
        let scopeSessionId = self.scopeSessionId
        reloadTask = Task { [weak self] in
            let sessions = await Self.loadSessions(catalog: catalog)
            let resolved = await Self.loadRows(
                catalog: catalog,
                previewStore: previewStore,
                minRating: minRating,
                scopeSessionId: scopeSessionId
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rows = resolved
                self.recentSessions = sessions
                if let currentSelection = self.selectedAssetId,
                   !resolved.contains(where: { $0.id == currentSelection }) {
                    self.selectedAssetId = nil
                }
            }
        }
    }

    /// Reload synchronously and wait for it to finish. Used by tests and
    /// by the harness' `state` command so callers can observe the freshly
    /// loaded rows without awaiting a publisher.
    public func reloadAndWait() async {
        reload()
        await reloadTask?.value
    }

    /// Set the current single-selection. Passing `nil` clears it.
    public func select(_ assetId: UUID?) {
        selectedAssetId = assetId
    }

    /// Request the full-resolution original for `assetId` via the
    /// injected `OriginalFetcher`. Tracks in-flight state on
    /// `downloadingAssetIds` so the Loupe overlay can show a spinner
    /// without callers having to orchestrate the UI side-effects. Returns
    /// `nil` when no fetcher is wired or the fetcher reports failure —
    /// callers must fall back to the preview in that case.
    public func fetchOriginalIfNeeded(assetId: UUID) async -> URL? {
        guard let fetcher = originalFetcher else { return nil }
        downloadingAssetIds.insert(assetId)
        defer { downloadingAssetIds.remove(assetId) }
        return await fetcher.fetchOriginal(assetId: assetId)
    }

    /// Move selection to the next row after the current selection. Wraps
    /// at the end? **No.** If nothing is selected or the current selection
    /// is already the last row, this is a no-op.
    public func selectNext() {
        let ids = rows.map(\.id)
        guard let next = Self.neighbor(in: ids, from: selectedAssetId, offset: 1) else {
            return
        }
        selectedAssetId = next
    }

    /// Move selection to the previous row before the current selection.
    /// No wrap at the start; no-op if nothing is selected or the current
    /// selection is already the first row.
    public func selectPrevious() {
        let ids = rows.map(\.id)
        guard let prev = Self.neighbor(in: ids, from: selectedAssetId, offset: -1) else {
            return
        }
        selectedAssetId = prev
    }

    /// Move selection up by one row in the grid (skip back by `columnCount`).
    /// No-op if nothing is selected or the target would be out of bounds.
    public func selectUp() {
        let ids = rows.map(\.id)
        guard let target = Self.neighbor(in: ids, from: selectedAssetId, offset: -Self.columnCount) else {
            return
        }
        selectedAssetId = target
    }

    /// Move selection down by one row in the grid (skip forward by `columnCount`).
    /// No-op if nothing is selected or the target would be out of bounds.
    public func selectDown() {
        let ids = rows.map(\.id)
        guard let target = Self.neighbor(in: ids, from: selectedAssetId, offset: Self.columnCount) else {
            return
        }
        selectedAssetId = target
    }

    /// Persist a new rating for `assetId` and reload the grid so the
    /// star overlay updates. `rating` must be in `0...5` — values outside
    /// that range are clamped because the UI key handlers bind 0–5 only.
    public func setRating(for assetId: UUID, to rating: Int) async {
        let clamped = max(0, min(5, rating))
        do {
            try catalog.updateRating(assetId: assetId, rating: clamped)
        } catch {
            // Catalog writes are rare and non-recoverable from the view.
            // Swallow and let the next reload surface a consistent state.
            return
        }
        if clamped > 0 {
            ratingToast = RatingToast(assetId: assetId, rating: clamped)
        } else {
            ratingToast = nil
        }
        await reloadAndWait()
    }

    /// Update the minimum-rating filter and reload the grid to match. If
    /// the previously-selected row no longer passes the filter, the
    /// shared `reload` bookkeeping clears the selection automatically.
    public func setMinRating(_ newValue: Int) async {
        let clamped = max(0, min(5, newValue))
        minRating = clamped
        await reloadAndWait()
    }

    /// Set the import-session scope and reload. Pass `nil` for "All Photos".
    public func setScope(_ sessionId: UUID?) async {
        scopeSessionId = sessionId
        await reloadAndWait()
    }

    /// Rotate `assetId` 90° in the given direction, invalidate its
    /// cached previews, regenerate them from the original file, and
    /// reload the grid so the new orientation is visible immediately.
    ///
    /// If the asset has no `localPath` (e.g. Drive-only), the rotation
    /// value is still written to the catalog — the preview just stays
    /// stale until something else triggers a regenerate. This matches
    /// the "originals on demand" constraint in CLAUDE.md: we cannot
    /// guarantee the original is present, so rotation must not require
    /// it to succeed.
    public func rotate(assetId: UUID, clockwise: Bool = true) async {
        let assets: [Asset]
        do {
            assets = try catalog.fetchAssets(filter: AssetFilter(includeDeleted: true))
        } catch {
            return
        }
        guard let asset = assets.first(where: { $0.id == assetId }) else {
            return
        }
        let newRotation: Int
        if clockwise {
            newRotation = (asset.rotation + 90) % 360
        } else {
            newRotation = (asset.rotation - 90 + 360) % 360
        }
        do {
            try catalog.updateRotation(assetId: assetId, rotation: newRotation)
        } catch {
            return
        }

        // Invalidate first so a parallel `generate` call from anywhere
        // else in the app doesn't short-circuit on stale files.
        await previewStore.invalidate(for: asset)
        if let localPath = asset.localPath {
            let sourceURL = URL(fileURLWithPath: localPath)
            // Build a fresh Asset value with the new rotation so
            // PreviewStore.applyRotation bakes the orientation into the
            // regenerated JPEGs. Catalog/cache agree afterwards.
            var rotated = asset
            rotated.rotation = newRotation
            _ = try? await previewStore.generate(for: rotated, sourceURL: sourceURL)
        }

        rowVersion &+= 1
        await reloadAndWait()
    }

    /// Pure bounds helper: given an ordered id list, the current
    /// selection, and an `offset` of `+1` or `-1`, return the id of the
    /// neighbour — or `nil` when moving past either edge, when no
    /// selection exists, or when the current selection isn't in the list.
    /// Exposed internally so Layer A tests can hit the math without
    /// building a live view model.
    nonisolated static func neighbor(
        in ids: [UUID],
        from current: UUID?,
        offset: Int
    ) -> UUID? {
        guard let current, let index = ids.firstIndex(of: current) else {
            return nil
        }
        let target = index + offset
        guard ids.indices.contains(target) else { return nil }
        return ids[target]
    }

    /// Background-task worker: read the catalog off the main thread, sort,
    /// and resolve thumbnail + preview URLs. Static so it can't accidentally
    /// touch `@MainActor` state.
    private static func loadRows(
        catalog: CatalogDatabase,
        previewStore: PreviewStore,
        minRating: Int,
        scopeSessionId: UUID? = nil
    ) async -> [LibraryRow] {
        await Task.detached(priority: .userInitiated) {
            let fetched: [Asset]
            do {
                let filter = AssetFilter(
                    rating: minRating == 0 ? nil : minRating,
                    importSessionId: scopeSessionId
                )
                fetched = try catalog.fetchAssets(filter: filter)
            } catch {
                // Catalog read failures are rare and non-recoverable from
                // the view. Surface them as an empty grid rather than
                // crashing.
                return []
            }
            let sorted = fetched.sorted { lhs, rhs in
                Self.effectiveDate(for: lhs) > Self.effectiveDate(for: rhs)
            }
            return sorted.map { asset in
                LibraryRow(
                    asset: asset,
                    thumbnailURL: previewStore.thumbnailURL(for: asset),
                    previewURL: previewStore.previewURL(for: asset)
                )
            }
        }.value
    }

    /// Background-task worker: fetch recent import sessions.
    private static func loadSessions(
        catalog: CatalogDatabase
    ) async -> [ImportSessionSummary] {
        await Task.detached(priority: .userInitiated) {
            (try? catalog.fetchImportSessions()) ?? []
        }.value
    }

    /// Sort key: prefer capture date (when a photo was taken) and fall
    /// back to import date for scans / screenshots that don't carry EXIF.
    /// Nonisolated so the background reload worker can call it.
    private nonisolated static func effectiveDate(for asset: Asset) -> Date {
        asset.captureDate ?? asset.importedDate
    }
}
