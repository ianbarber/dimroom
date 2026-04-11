import Foundation

/// Summary of a single `FolderImporter.importFolder(_:)` call.
public struct ImportResult: Sendable, Equatable {
    /// Number of new assets inserted into the catalog.
    public let importedCount: Int
    /// Number of files that were hashed but already present in the catalog
    /// (dedup hits). Files filtered out by the extension allowlist or
    /// hidden-file rules do not increment this counter.
    public let skippedCount: Int
    /// Identifier of the `ImportSession` row created for this call.
    public let sessionId: UUID

    public init(importedCount: Int, skippedCount: Int, sessionId: UUID) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.sessionId = sessionId
    }
}
