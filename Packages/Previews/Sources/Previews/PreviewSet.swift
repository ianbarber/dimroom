import Foundation

/// The file URLs for both cached previews of an asset.
public struct PreviewSet: Sendable, Equatable {
    public let thumbnail: URL
    public let preview: URL

    public init(thumbnail: URL, preview: URL) {
        self.thumbnail = thumbnail
        self.preview = preview
    }
}
