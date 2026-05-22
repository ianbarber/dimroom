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
///
/// Constructed in two phases: the cache needs an `onEvict` callback that
/// points at `handleEviction`, and `handleEviction` needs the catalog —
/// so we build the coordinator first and `attach` the cache once it's
/// available. Post-attach, the coordinator owns the cache for its
/// lifetime.
final class OriginalsCoordinator: OriginalFetcher, Sendable {
    private let catalog: CatalogDatabase
    private let cacheBox: CacheBox

    init(catalog: CatalogDatabase) {
        self.catalog = catalog
        self.cacheBox = CacheBox()
    }

    /// Install the cache. Must be called exactly once before any
    /// `fetchOriginal` call; subsequent calls replace the reference
    /// (kept loose for testability, not for hot-swap in production).
    func attach(cache: OriginalsCache) {
        cacheBox.set(cache)
    }

    /// Return a local URL for `assetId`, downloading from Drive if
    /// needed. Returns `nil` on any failure so the UI degrades to the
    /// preview-resolution image. `progress` is forwarded straight to
    /// `OriginalsCache.fetch`; the cached-hit path is silent so callers
    /// know not to expect ticks.
    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        guard let cache = cacheBox.get() else { return nil }
        guard let asset = try? catalog.fetchAsset(id: assetId) else { return nil }
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
                progress: progress
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

    /// Forward a new byte budget to the underlying cache so the
    /// Settings UI / harness can retune eviction without rebuilding
    /// the coordinator.
    func setCacheBudget(_ bytes: Int64) async {
        guard let cache = cacheBox.get() else { return }
        await cache.setBudget(bytes)
    }

    /// Wipe every cached original on disk and clear the in-memory
    /// index. Used by the "Clear originals cache" button and the
    /// harness `clearOriginalsCache` command.
    func clearCache() async {
        guard let cache = cacheBox.get() else { return }
        await cache.clearAll()
    }
}

/// Tiny locked box holding the cache reference. Lets `OriginalsCoordinator`
/// stay `Sendable` (not `@unchecked`) while still supporting the two-phase
/// init the cache's `onEvict` callback requires.
private final class CacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: OriginalsCache?

    func set(_ cache: OriginalsCache) {
        lock.lock(); defer { lock.unlock() }
        self.cache = cache
    }

    func get() -> OriginalsCache? {
        lock.lock(); defer { lock.unlock() }
        return cache
    }
}
