import Foundation

/// On-disk manifest for the originals cache. One entry per cached asset
/// id, persisted as JSON next to the files so the cache survives process
/// restart. Kept deliberately small — anything that belongs in the
/// catalog should live in the catalog, not here.
struct OriginalsCacheIndex: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var filename: String
        var bytes: Int64
        var lastAccess: Date
        /// When `true`, the file is the only local copy (e.g. an asset
        /// imported but not yet uploaded to Drive). Eviction skips these.
        var pinned: Bool
    }

    var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    static func load(from url: URL) -> OriginalsCacheIndex {
        guard let data = try? Data(contentsOf: url) else {
            return OriginalsCacheIndex()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(OriginalsCacheIndex.self, from: data)) ?? OriginalsCacheIndex()
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
}
