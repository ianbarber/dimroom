import Foundation

/// LRU-evicted local cache for originals fetched from Drive on demand.
///
/// Callers ask `fetch(assetId:driveFileId:suggestedFilename:progress:)`
/// for a local URL; on a hit we bump `lastAccess` and return, on a miss
/// we download via the injected `OriginalsDownloader`, write atomically,
/// update the index, and evict the least-recently-accessed entries
/// until the total is under `budgetBytes`.
///
/// Actor isolation guarantees index mutations and in-flight dedup are
/// serialised without a separate lock. Concurrent callers for the same
/// asset id share the same download task.
public actor OriginalsCache {
    public let directory: URL
    public let budgetBytes: Int64
    private let downloader: OriginalsDownloader
    private let clock: @Sendable () -> Date
    private let onEvict: @Sendable (UUID) -> Void
    private let fileManager: FileManager

    private var index: OriginalsCacheIndex
    private var inFlight: [UUID: Task<URL, Error>]
    private let indexURL: URL

    public init(
        directory: URL,
        budgetBytes: Int64 = 10 * 1024 * 1024 * 1024,
        downloader: OriginalsDownloader,
        clock: @escaping @Sendable () -> Date = { Date() },
        onEvict: @escaping @Sendable (UUID) -> Void = { _ in },
        fileManager: FileManager = .default
    ) throws {
        self.directory = directory
        self.budgetBytes = budgetBytes
        self.downloader = downloader
        self.clock = clock
        self.onEvict = onEvict
        self.fileManager = fileManager
        self.inFlight = [:]
        self.indexURL = directory.appendingPathComponent("index.json")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.index = OriginalsCacheIndex.load(from: indexURL)
    }

    /// Local URL for an asset if it's already cached, without issuing a
    /// download or mutating access time.
    public func cachedURL(for assetId: UUID) -> URL? {
        guard let entry = index.entries[assetId.uuidString] else { return nil }
        let url = directory.appendingPathComponent(entry.filename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Current cache size in bytes. Computed from the index, not from
    /// an O(n) filesystem walk, so it's cheap to call.
    public func currentSizeBytes() -> Int64 {
        index.totalBytes
    }

    /// Bump `lastAccess` for an asset id without fetching. Safe to call
    /// for ids that aren't in the cache (no-op).
    public func touch(assetId: UUID) {
        guard var entry = index.entries[assetId.uuidString] else { return }
        entry.lastAccess = clock()
        index.entries[assetId.uuidString] = entry
        try? index.save(to: indexURL)
    }

    /// Return a local URL for the original. On a hit, bumps the access
    /// time. On a miss, downloads via `OriginalsDownloader`, writes
    /// under `directory`, updates the index, and evicts LRU entries to
    /// stay within `budgetBytes`.
    public func fetch(
        assetId: UUID,
        driveFileId: String,
        suggestedFilename: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let cached = cachedURL(for: assetId) {
            touch(assetId: assetId)
            return cached
        }

        if let existing = inFlight[assetId] {
            return try await existing.value
        }

        let task = Task<URL, Error> { [directory, downloader, fileManager] in
            let filename = "\(assetId.uuidString)-\(suggestedFilename)"
            let destination = directory.appendingPathComponent(filename)
            let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)-\(suggestedFilename)")

            do {
                try await downloader.download(driveFileId: driveFileId, to: tempURL, progress: progress)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                if let cacheError = error as? OriginalsCacheError {
                    throw cacheError
                }
                if case let DriveClientError.downloadFailed(status) = error {
                    throw OriginalsCacheError.downloadFailed(status: status)
                }
                throw OriginalsCacheError.unreachable
            }

            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: tempURL, to: destination)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw OriginalsCacheError.ioFailure
            }
            return destination
        }
        inFlight[assetId] = task
        defer { inFlight[assetId] = nil }

        let destination: URL
        do {
            destination = try await task.value
        } catch {
            throw error
        }

        let attrs = (try? fileManager.attributesOfItem(atPath: destination.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        index.entries[assetId.uuidString] = OriginalsCacheIndex.Entry(
            filename: destination.lastPathComponent,
            bytes: size,
            lastAccess: clock()
        )
        evictIfNeeded(protectedId: assetId)
        try? index.save(to: indexURL)
        return destination
    }

    // MARK: - Eviction

    private func evictIfNeeded(protectedId: UUID) {
        guard index.totalBytes > budgetBytes else { return }
        let sorted = index.entries
            .filter { $0.key != protectedId.uuidString }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }

        for (key, entry) in sorted {
            if index.totalBytes <= budgetBytes { break }
            let fileURL = directory.appendingPathComponent(entry.filename)
            try? fileManager.removeItem(at: fileURL)
            index.entries.removeValue(forKey: key)
            if let evictedId = UUID(uuidString: key) {
                onEvict(evictedId)
            }
        }
    }
}
