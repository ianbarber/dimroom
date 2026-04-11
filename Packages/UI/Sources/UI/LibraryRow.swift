import Catalog
import Foundation

/// Precomputed grid row consumed by `LibraryCell` and `LoupeView`. The
/// view model resolves the thumbnail and preview URLs once, up-front, so
/// neither the cell nor the loupe renderer has to touch `PreviewStore`
/// in its render path.
public struct LibraryRow: Identifiable, Sendable {
    public let asset: Asset
    public let thumbnailURL: URL?
    public let previewURL: URL?

    public var id: UUID { asset.id }

    public init(asset: Asset, thumbnailURL: URL?, previewURL: URL?) {
        self.asset = asset
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
    }
}
