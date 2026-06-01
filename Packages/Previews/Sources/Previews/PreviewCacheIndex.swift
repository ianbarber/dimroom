import Foundation

/// On-disk manifest for the preview cache. One entry per cached JPEG
/// (per tier, per kind), persisted as `index.json` at the cache root so
/// the size accounting survives process restart. Direct analogue of
/// `OriginalsCacheIndex` — kept deliberately small; anything that belongs
/// in the catalog lives in the catalog, not here.
///
/// Entries are keyed by the file's path **relative to the cache root**
/// (e.g. `"ab/ab12cd.thumb.jpg"`, `"ab/ab12cd.edit.preview.jpg"`). Using
/// the relative path as the key — rather than a synthetic
/// `<hash>.<tier>.<kind>` composite — means `rebuild(from:)` can index a
/// pre-existing cache by walking the directory without having to parse
/// filenames back into (contentHash, tier, kind), and eviction can map a
/// key straight back to a URL with `root.appendingPathComponent(key)`.
///
/// Cache files always live exactly two levels under the root —
/// `<root>/<2-char shard>/<filename>.jpg` (see `CachePaths`) — so the key
/// is the file URL's last two path components. Deriving it that way is
/// immune to the `/var` vs `/private/var` symlink rewriting that
/// `FileManager.enumerator` applies, which a root-prefix strip would trip
/// over (the enumerator's resolved URLs wouldn't match the unresolved
/// root, silently producing bare-filename keys that eviction couldn't map
/// back to their shard subdirectory).
struct PreviewCacheIndex: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var bytes: Int64
        var lastAccess: Date
    }

    var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The index key for a cached file: the `<shard>/<filename>` pair that
    /// is its path relative to the cache root. Taken as the last two path
    /// components so it agrees whether the URL was freshly built from the
    /// (unresolved) root or yielded by `FileManager.enumerator` (which
    /// rewrites `/var` to `/private/var`).
    static func key(for fileURL: URL) -> String {
        let components = fileURL.pathComponents
        guard components.count >= 2 else { return fileURL.lastPathComponent }
        return components.suffix(2).joined(separator: "/")
    }

    static func load(from url: URL) -> PreviewCacheIndex {
        guard let data = try? Data(contentsOf: url) else {
            return PreviewCacheIndex()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PreviewCacheIndex.self, from: data)) ?? PreviewCacheIndex()
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    var totalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.bytes }
    }

    /// Build an index by walking an existing cache directory. Used on
    /// first launch after this feature lands, when `index.json` is absent
    /// but the cache already holds preview JPEGs from earlier sessions, so
    /// budget enforcement accounts for those pre-existing bytes. Each
    /// file's `lastAccess` is seeded from its modification date — the best
    /// available proxy for "least recently generated".
    static func rebuild(from cacheRoot: URL, fileManager: FileManager) -> PreviewCacheIndex {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return PreviewCacheIndex()
        }

        var entries: [String: Entry] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "jpg" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { continue }
            let bytes = Int64(values?.fileSize ?? 0)
            let lastAccess = values?.contentModificationDate ?? Date()
            entries[key(for: url)] = Entry(bytes: bytes, lastAccess: lastAccess)
        }
        return PreviewCacheIndex(entries: entries)
    }
}
