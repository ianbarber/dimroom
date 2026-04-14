import Foundation

/// Narrow seam the UI uses to request an original's local URL without
/// knowing anything about Drive, OAuth, or the cache. The app-level
/// `OriginalsCoordinator` implements this; tests can plug in any stub.
public protocol OriginalFetcher: Sendable {
    /// Return a local URL for the original backing `assetId`, or `nil`
    /// if unavailable (Drive unreachable, no `driveFileId`, I/O failure).
    /// Implementations must not throw — the UI treats `nil` as "degrade
    /// to preview-only".
    func fetchOriginal(assetId: UUID) async -> URL?
}
