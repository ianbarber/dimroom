import CoreGraphics
import Foundation

/// The two sizes the preview cache produces per asset.
///
/// The package is intentionally opinionated: it generates exactly these two
/// files for every asset. Higher-level code picks between them based on
/// whether it's showing a grid cell (thumbnail) or a full-screen view
/// (preview).
public enum PreviewKind: String, CaseIterable, Sendable {
    case thumbnail
    case preview

    /// Maximum size of the longest edge, in pixels, for this preview kind.
    var maxEdge: CGFloat {
        switch self {
        case .thumbnail: return 256
        case .preview: return 2048
        }
    }

    /// The filename tag used on disk for this preview kind. Chosen to be
    /// short and unambiguous: `<contentHash>.thumb.jpg` / `<contentHash>.preview.jpg`.
    var tag: String {
        switch self {
        case .thumbnail: return "thumb"
        case .preview: return "preview"
        }
    }
}
