import Catalog
import DriveClient
import Foundation
import UI

/// App-level façade that plugs the `OriginalsCache` into the three
/// triggers described in CLAUDE.md: Loupe deep-zoom, export with
/// `applyEdits`, and the EditEngine full-res render path. Owns the
/// mapping between asset ids and Drive file ids via the catalog, and
/// keeps `Asset.localPath` in sync so other parts of the app don't have
/// to go through this façade to read originals.
final class OriginalsCoordinator: OriginalFetcher, @unchecked Sendable {
    private let cache: OriginalsCache
    private let catalog: CatalogDatabase

    init(cache: OriginalsCache, catalog: CatalogDatabase) {
        self.cache = cache
        self.catalog = catalog
    }

    /// Return a local URL for `assetId`, downloading from Drive if
    /// needed. Returns `nil` on any failure so the UI degrades to the
    /// preview-resolution image.
    func fetchOriginal(assetId: UUID) async -> URL? {
        guard let asset = try? lookupAsset(id: assetId) else { return nil }
        if let existing = asset.localPath {
            let url = URL(fileURLWithPath: existing)
            if FileManager.default.fileExists(atPath: url.path) {
                await cache.touch(assetId: assetId)
                return url
            }
        }
        guard let driveFileId = asset.driveFileId else { return nil }
        do {
            let url = try await cache.fetch(
                assetId: assetId,
                driveFileId: driveFileId,
                suggestedFilename: asset.originalFilename,
                progress: nil
            )
            try? catalog.updateLocalPath(assetId: assetId, path: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Callback suitable for `OriginalsCache.onEvict`. Clears the local
    /// path so downstream callers re-download instead of opening a file
    /// that's no longer on disk.
    func handleEviction(assetId: UUID) {
        try? catalog.updateLocalPath(assetId: assetId, path: nil)
    }

    private func lookupAsset(id: UUID) throws -> Asset? {
        let filter = AssetFilter(includeDeleted: true)
        let assets = try catalog.fetchAssets(filter: filter)
        return assets.first(where: { $0.id == id })
    }
}
