import Catalog
import Foundation

/// Pure helpers that compute cache URLs from a content hash. Kept in its
/// own file so it can be tested independently of any filesystem or Core
/// Image state.
enum CachePaths {
    /// Directory that contains both preview files for a single asset.
    ///
    /// The first two characters of the content hash act as a sharding
    /// prefix, so one directory never accumulates tens of thousands of
    /// files. A short hash like `"ab"` shards into `root/ab/`.
    static func directory(for contentHash: String, in root: URL) -> URL {
        let prefix = String(contentHash.prefix(2))
        return root.appendingPathComponent(prefix, isDirectory: true)
    }

    static func directory(for asset: Asset, in root: URL) -> URL {
        directory(for: asset.contentHash, in: root)
    }

    /// The JPEG URL for one preview kind of one asset.
    static func fileURL(
        for contentHash: String,
        kind: PreviewKind,
        in root: URL
    ) -> URL {
        directory(for: contentHash, in: root)
            .appendingPathComponent("\(contentHash).\(kind.tag).jpg", isDirectory: false)
    }

    static func fileURL(
        for asset: Asset,
        kind: PreviewKind,
        in root: URL
    ) -> URL {
        fileURL(for: asset.contentHash, kind: kind, in: root)
    }
}
