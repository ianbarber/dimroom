import Foundation

/// Narrow seam the UI uses to request an original's local URL without
/// knowing anything about Drive, OAuth, or the cache. The app-level
/// `OriginalsCoordinator` implements this; tests can plug in any stub.
public protocol OriginalFetcher: Sendable {
    /// Return a local URL for the original backing `assetId`, or `nil`
    /// if unavailable (Drive unreachable, no `driveFileId`, I/O failure).
    /// Implementations must not throw — the UI treats `nil` as "degrade
    /// to preview-only".
    ///
    /// `progress`, when supplied, is invoked zero or more times with a
    /// `0.0...1.0` fraction while bytes are streaming. Conformers that
    /// cannot report progress (unknown `Content-Length`, cached hit)
    /// should simply not invoke it — callers fall back to an
    /// indeterminate spinner when no value arrives.
    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL?
}

public extension OriginalFetcher {
    /// Convenience: no progress callback. Keeps existing call sites
    /// (Export, Harness) source-compatible with the pre-progress API.
    func fetchOriginal(assetId: UUID) async -> URL? {
        await fetchOriginal(assetId: assetId, progress: nil)
    }
}
