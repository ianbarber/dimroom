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

    private let catalog: CatalogDatabase
    private let previewStore: PreviewStore
    private var reloadTask: Task<Void, Never>?

    public init(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
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
        reloadTask = Task { [weak self] in
            let resolved = await Self.loadRows(
                catalog: catalog,
                previewStore: previewStore
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rows = resolved
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
        previewStore: PreviewStore
    ) async -> [LibraryRow] {
        await Task.detached(priority: .userInitiated) {
            let fetched: [Asset]
            do {
                fetched = try catalog.fetchAssets(filter: AssetFilter())
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

    /// Sort key: prefer capture date (when a photo was taken) and fall
    /// back to import date for scans / screenshots that don't carry EXIF.
    /// Nonisolated so the background reload worker can call it.
    private nonisolated static func effectiveDate(for asset: Asset) -> Date {
        asset.captureDate ?? asset.importedDate
    }
}
