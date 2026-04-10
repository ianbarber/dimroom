import Foundation

public struct AssetFilter: Sendable {
    public var rating: Int?
    public var sourceType: Asset.SourceType?
    public var includeDeleted: Bool

    public init(
        rating: Int? = nil,
        sourceType: Asset.SourceType? = nil,
        includeDeleted: Bool = false
    ) {
        self.rating = rating
        self.sourceType = sourceType
        self.includeDeleted = includeDeleted
    }
}
