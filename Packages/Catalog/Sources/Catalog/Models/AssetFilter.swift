import Foundation

public struct AssetFilter: Sendable {
    public var rating: Int?
    public var sourceType: Asset.SourceType?
    public var includeDeleted: Bool
    public var importSessionId: UUID?

    public init(
        rating: Int? = nil,
        sourceType: Asset.SourceType? = nil,
        includeDeleted: Bool = false,
        importSessionId: UUID? = nil
    ) {
        self.rating = rating
        self.sourceType = sourceType
        self.includeDeleted = includeDeleted
        self.importSessionId = importSessionId
    }
}
