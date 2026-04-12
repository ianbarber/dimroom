import Foundation

/// Lightweight projection of an import session with its asset count,
/// returned by `CatalogDatabase.fetchImportSessions(limit:)`.
public struct ImportSessionSummary: Identifiable, Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let assetCount: Int
    public let startedAt: Date

    public init(id: UUID, displayName: String, assetCount: Int, startedAt: Date) {
        self.id = id
        self.displayName = displayName
        self.assetCount = assetCount
        self.startedAt = startedAt
    }
}
