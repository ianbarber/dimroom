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
    /// Full multi-selection. Plain click collapses to a single id; Cmd-click
    /// toggles individual ids; Shift-click extends from `selectionAnchorId`.
    /// All write paths go through `selectSingle` / `toggleSelect` /
    /// `extendSelect` / `selectAllVisible` so the anchor and primary stay
    /// consistent.
    @Published public private(set) var selectedAssetIds: Set<UUID> = []
    /// Last-clicked id, used by Loupe/Develop to pick which asset to show
    /// when the grid has multiple cells selected. Always a member of
    /// `selectedAssetIds` when non-nil.
    @Published public private(set) var primarySelectedAssetId: UUID?
    /// Anchor for Shift-click range selection. Set by plain-click and
    /// Cmd-click; reused by subsequent Shift-click to compute the range.
    public private(set) var selectionAnchorId: UUID?
    /// Minimum rating currently required for a row to appear in `rows`.
    /// `0` (the default) means "show everything". Any other value in
    /// `1...5` hides rows whose asset has a lower rating. Mutating this
    /// directly does **not** trigger a reload — callers should go through
    /// `setMinRating(_:)` so the grid is re-queried.
    @Published public private(set) var minRating: Int = 0
    /// Currently active scope: All Photos, a specific import session, or
    /// the Recently Deleted trash.
    @Published public private(set) var scope: Scope = .all
    /// Recent import sessions for the scope picker.
    @Published public private(set) var recentSessions: [ImportSessionSummary] = []
    /// Transient toast shown for 10 seconds after a soft-delete; clicking
    /// Undo from the toast restores the assets in the toast's `deletedIds`.
    @Published public var undoToast: UndoToast?
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

    /// Scroll-to trigger set by arrow-key navigation methods. LibraryView
    /// observes this via `.onChange` and calls `ScrollViewProxy.scrollTo`
    /// then clears it. Tap/harness `select(_:)` does not set this.
    @Published public var pendingScrollToAssetId: UUID?

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

    /// Active library scope. `.session(id)` narrows the grid to one
    /// import session; `.recentlyDeleted` shows the trash (soft-deleted
    /// rows only).
    public enum Scope: Equatable, Sendable {
        case all
        case session(UUID)
        case recentlyDeleted
    }

    /// Value attached to `undoToast` after a soft-delete. Carries the
    /// deleted ids so `undoLastDelete` can restore exactly what the user
    /// just removed, even if the grid has reloaded in the meantime.
    public struct UndoToast: Equatable, Sendable {
        public let deletedIds: [UUID]
        public let deletedAt: Date

        public init(deletedIds: [UUID], deletedAt: Date = Date()) {
            self.deletedIds = deletedIds
            self.deletedAt = deletedAt
        }
    }

    /// How long the undo toast stays on screen before auto-dismissing.
    /// After this window, `undoLastDelete` is a no-op from the toast's
    /// perspective — the trash scope remains the path to restore.
    public static let undoToastDuration: Duration = .seconds(10)

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
    private var undoDismissTask: Task<Void, Never>?

    /// Shared undo stack used to record rating/rotation mutations. Set
    /// by `AppDelegate` after construction; `nil` in the placeholder
    /// view model and in tests that don't exercise undo.
    public weak var undoStack: UndoStack?

    /// Backwards-compatible alias for the primary (last-clicked) selection.
    /// External callers that still think of selection as a single id — the
    /// Loupe view, the harness `AppState`, existing tests — read this.
    /// Assigning through `select(_:)` continues to work: the setter
    /// collapses the multi-selection down to the given single id.
    public var selectedAssetId: UUID? {
        primarySelectedAssetId
    }

    /// Backwards-compatible alias for the legacy import-session scope
    /// field. Returns the `session(id)` payload or `nil` when the scope
    /// is `.all` / `.recentlyDeleted`.
    public var scopeSessionId: UUID? {
        if case .session(let id) = scope { return id }
        return nil
    }

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

    /// Reload the current-scope assets from the catalog, sort them
    /// newest-first, and resolve their thumbnail URLs. The catalog read
    /// happens on a background task so the main thread never blocks on
    /// SQLite; the result is published on `MainActor`. If the primary
    /// selection disappears on reload, selection is cleared. If anything
    /// in the multi-selection disappears, those ids are dropped too.
    ///
    /// Synchronous for test ergonomics: tests can call `reload()` and
    /// inspect `rows` on the next `await` without an expectation dance.
    /// In production the cost is one Task hop, which is negligible.
    public func reload() {
        reloadTask?.cancel()
        let catalog = self.catalog
        let previewStore = self.previewStore
        let minRating = self.minRating
        let scope = self.scope
        reloadTask = Task { [weak self] in
            let sessions = await Self.loadSessions(catalog: catalog)
            let resolved = await Self.loadRows(
                catalog: catalog,
                previewStore: previewStore,
                minRating: minRating,
                scope: scope
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rows = resolved
                self.recentSessions = sessions
                let visible = Set(resolved.map(\.id))
                let retained = self.selectedAssetIds.intersection(visible)
                if retained != self.selectedAssetIds {
                    self.selectedAssetIds = retained
                }
                if let primary = self.primarySelectedAssetId, !visible.contains(primary) {
                    self.primarySelectedAssetId = retained.first
                }
                if let anchor = self.selectionAnchorId, !visible.contains(anchor) {
                    self.selectionAnchorId = retained.first
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

    /// Set the current single-selection (plain click / selectAsset
    /// command). Collapses any existing multi-selection down to this one
    /// id and resets the shift-click anchor. Passing `nil` clears
    /// selection entirely.
    public func select(_ assetId: UUID?) {
        if let assetId {
            selectedAssetIds = [assetId]
            primarySelectedAssetId = assetId
            selectionAnchorId = assetId
        } else {
            selectedAssetIds = []
            primarySelectedAssetId = nil
            selectionAnchorId = nil
        }
    }

    /// Cmd-click: add or remove `assetId` from the multi-selection. The
    /// anchor and primary move to `assetId` when adding; when removing,
    /// the primary falls back to any remaining selected id so the Loupe
    /// still has something to show.
    public func toggleSelect(_ assetId: UUID) {
        if selectedAssetIds.contains(assetId) {
            selectedAssetIds.remove(assetId)
            if primarySelectedAssetId == assetId {
                primarySelectedAssetId = selectedAssetIds.first
            }
            if selectionAnchorId == assetId {
                selectionAnchorId = primarySelectedAssetId
            }
        } else {
            selectedAssetIds.insert(assetId)
            primarySelectedAssetId = assetId
            selectionAnchorId = assetId
        }
    }

    /// Shift-click: extend the selection to cover every row between the
    /// current anchor and `assetId` (inclusive). If there is no anchor
    /// yet, behaves like a plain single-select. The anchor itself does
    /// not move so subsequent shift-clicks keep extending from the same
    /// origin. Clears non-range ids to match Finder behaviour.
    public func extendSelect(to assetId: UUID) {
        guard let anchor = selectionAnchorId,
              let anchorIndex = rows.firstIndex(where: { $0.id == anchor }),
              let targetIndex = rows.firstIndex(where: { $0.id == assetId }) else {
            select(assetId)
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selectedAssetIds = Set(rows[range].map(\.id))
        primarySelectedAssetId = assetId
    }

    /// Cmd+A: select every row currently in `rows`. Primary lands on the
    /// first visible row so the Loupe has a deterministic pick.
    public func selectAllVisible() {
        guard !rows.isEmpty else { return }
        selectedAssetIds = Set(rows.map(\.id))
        primarySelectedAssetId = rows.first?.id
        selectionAnchorId = rows.first?.id
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
        guard let next = Self.neighbor(in: ids, from: primarySelectedAssetId, offset: 1) else {
            return
        }
        select(next)
        pendingScrollToAssetId = next
    }

    /// Move selection to the previous row before the current selection.
    /// No wrap at the start; no-op if nothing is selected or the current
    /// selection is already the first row.
    public func selectPrevious() {
        let ids = rows.map(\.id)
        guard let prev = Self.neighbor(in: ids, from: primarySelectedAssetId, offset: -1) else {
            return
        }
        select(prev)
        pendingScrollToAssetId = prev
    }

    /// Move selection up by one row in the grid (skip back by `columnCount`).
    /// No-op if nothing is selected or the target would be out of bounds.
    public func selectUp() {
        let ids = rows.map(\.id)
        guard let target = Self.neighbor(in: ids, from: primarySelectedAssetId, offset: -Self.columnCount) else {
            return
        }
        select(target)
        pendingScrollToAssetId = target
    }

    /// Move selection down by one row in the grid (skip forward by `columnCount`).
    /// No-op if nothing is selected or the target would be out of bounds.
    public func selectDown() {
        let ids = rows.map(\.id)
        guard let target = Self.neighbor(in: ids, from: primarySelectedAssetId, offset: Self.columnCount) else {
            return
        }
        select(target)
        pendingScrollToAssetId = target
    }

    /// Soft-delete every currently-selected asset, clear the selection,
    /// reload, and show the undo toast for `undoToastDuration`. Used by
    /// the UI's Delete/Backspace path and the harness' `deleteAssets`
    /// command.
    public func deleteSelected() async {
        let ids = Array(selectedAssetIds)
        guard !ids.isEmpty else { return }
        await deleteAssets(ids: ids)
    }

    /// Soft-delete `ids` explicitly (used by the harness). Mirrors
    /// `deleteSelected` but doesn't require the ids to be in
    /// `selectedAssetIds`.
    public func deleteAssets(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let deleted: [UUID]
        do {
            deleted = try catalog.deleteAssets(ids: ids)
        } catch {
            return
        }
        guard !deleted.isEmpty else { return }
        select(nil)
        await reloadAndWait()
        showUndoToast(for: deleted)
        undoStack?.push(.softDelete(assetIds: deleted))
    }

    /// Clear `deletedAt` on the given ids and reload. Unlike
    /// `undoLastDelete`, this works from the Recently Deleted scope at
    /// any time — not just while the toast is visible.
    public func restoreAssets(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            try catalog.restoreAssets(ids: ids)
        } catch {
            return
        }
        await reloadAndWait()
    }

    /// Permanently remove assets from the catalog and purge their
    /// previews (and cached originals on disk, if any). Used from the
    /// Recently Deleted scope.
    public func permanentlyDeleteAssets(ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        let removed: [Asset]
        do {
            removed = try catalog.permanentlyDeleteAssets(ids: ids)
        } catch {
            return
        }
        for asset in removed {
            await previewStore.invalidate(for: asset)
            if let localPath = asset.localPath {
                try? FileManager.default.removeItem(atPath: localPath)
            }
        }
        await reloadAndWait()
    }

    /// Action attached to the toast's Undo button: restore the ids in
    /// the most recent toast and dismiss. If the toast already timed
    /// out, this is a no-op — the user must use the Recently Deleted
    /// scope at that point.
    public func undoLastDelete() async {
        guard let toast = undoToast else { return }
        await restoreAssets(ids: toast.deletedIds)
        undoToast = nil
        undoDismissTask?.cancel()
        undoDismissTask = nil
    }

    private func showUndoToast(for deletedIds: [UUID]) {
        undoDismissTask?.cancel()
        undoToast = UndoToast(deletedIds: deletedIds)
        undoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoToastDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.undoToast = nil
            }
        }
    }

    /// Persist a new rating for `assetId` and reload the grid so the
    /// star overlay updates. `rating` must be in `0...5` — values outside
    /// that range are clamped because the UI key handlers bind 0–5 only.
    public func setRating(for assetId: UUID, to rating: Int) async {
        let clamped = max(0, min(5, rating))
        let previous = (try? catalog.fetchAsset(id: assetId)?.rating) ?? 0
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
        if previous != clamped {
            undoStack?.push(.rating(assetId: assetId, from: previous, to: clamped))
        }
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
        await setScope(sessionId.map { Scope.session($0) } ?? .all)
    }

    /// Set the library scope to an arbitrary `Scope` value (covers All
    /// Photos, a specific import session, and Recently Deleted) and
    /// reload.
    public func setScope(_ newScope: Scope) async {
        scope = newScope
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
        guard let asset = try? catalog.fetchAsset(id: assetId) else {
            return
        }
        let newRotation: Int
        if clockwise {
            newRotation = (asset.rotation + 90) % 360
        } else {
            newRotation = (asset.rotation - 90 + 360) % 360
        }
        let previousRotation = asset.rotation
        await applyRotation(assetId: assetId, to: newRotation)
        if previousRotation != newRotation {
            undoStack?.push(.rotation(
                assetId: assetId,
                from: previousRotation,
                to: newRotation
            ))
        }
    }

    /// Set an absolute rotation on `assetId` and regenerate its cached
    /// previews to match. Shared between `rotate(clockwise:)` (the
    /// forward entrypoint) and the undo stack (which needs to replay
    /// rotations at absolute values, not deltas).
    public func applyRotation(assetId: UUID, to rotation: Int) async {
        guard let asset = try? catalog.fetchAsset(id: assetId) else {
            return
        }
        do {
            try catalog.updateRotation(assetId: assetId, rotation: rotation)
        } catch {
            return
        }

        // Invalidate first so a parallel `generate` call from anywhere
        // else in the app doesn't short-circuit on stale files.
        await previewStore.invalidate(for: asset)
        if let localPath = asset.localPath {
            let sourceURL = URL(fileURLWithPath: localPath)
            var rotated = asset
            rotated.rotation = rotation
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
        scope: Scope
    ) async -> [LibraryRow] {
        await Task.detached(priority: .userInitiated) {
            let fetched: [Asset]
            do {
                let sessionId: UUID?
                let onlyDeleted: Bool
                switch scope {
                case .all:
                    sessionId = nil
                    onlyDeleted = false
                case .session(let id):
                    sessionId = id
                    onlyDeleted = false
                case .recentlyDeleted:
                    sessionId = nil
                    onlyDeleted = true
                }
                let filter = AssetFilter(
                    rating: minRating == 0 ? nil : minRating,
                    includeDeleted: onlyDeleted,
                    onlyDeleted: onlyDeleted,
                    importSessionId: sessionId
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
