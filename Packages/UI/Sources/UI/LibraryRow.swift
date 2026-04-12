import Catalog
import Foundation

/// Precomputed grid row consumed by `LibraryCell`. The view model resolves
/// the thumbnail URL once, up-front, so the cell never has to touch
/// `PreviewStore` in its render path.
public struct LibraryRow: Identifiable, Sendable {
    public let asset: Asset
    public let thumbnailURL: URL?

    public var id: UUID { asset.id }

    public init(asset: Asset, thumbnailURL: URL?) {
        self.asset = asset
        self.thumbnailURL = thumbnailURL
    }
}
