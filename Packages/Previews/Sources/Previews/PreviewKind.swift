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

/// Which generation tier a cache file belongs to.
///
/// `.master` is written exactly once per asset, from the original, by
/// `PreviewStore.generate(for:sourceURL:)`. It is never overwritten by
/// later edits — every `regenerateWithEdit` call reads from this tier, so
/// repeated saves don't accumulate JPEG generation loss (issue #186).
///
/// `.display` is written by `regenerateWithEdit`. It carries the visible
/// edited look that Library + Loupe show. When `EditState` is identity
/// the display tier is deleted so lookups fall back to master.
public enum PreviewTier: Sendable {
    case master
    case display

    /// Filename infix between `<contentHash>` and the kind tag. Master
    /// keeps the existing `<hash>.thumb.jpg` / `<hash>.preview.jpg` layout
    /// so caches written before the tier split remain valid; display
    /// adds `.edit.` giving `<hash>.edit.thumb.jpg` /
    /// `<hash>.edit.preview.jpg`.
    var filenameInfix: String {
        switch self {
        case .master: return ""
        case .display: return "edit."
        }
    }
}
