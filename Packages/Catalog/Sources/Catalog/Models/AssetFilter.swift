import Foundation

public struct AssetFilter: Sendable {
    public var rating: Int?
    public var sourceType: Asset.SourceType?
    public var includeDeleted: Bool
    /// When `true`, return *only* soft-deleted rows (`deletedAt != NULL`).
    /// Implies `includeDeleted == true`. Used by the Recently Deleted
    /// scope so the grid can show the trash without live rows mixed in.
    public var onlyDeleted: Bool
    public var importSessionId: UUID?

    public init(
        rating: Int? = nil,
        sourceType: Asset.SourceType? = nil,
        includeDeleted: Bool = false,
        onlyDeleted: Bool = false,
        importSessionId: UUID? = nil
    ) {
        self.rating = rating
        self.sourceType = sourceType
        self.includeDeleted = includeDeleted
        self.onlyDeleted = onlyDeleted
        self.importSessionId = importSessionId
    }
}
