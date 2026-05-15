import Foundation

/// Errors raised by `CatalogPublisher` and the supporting catalog
/// upload/restore machinery. Wrapped strings hold the underlying
/// description rather than the original `Error` so the enum stays
/// `Equatable` and the values are easy to surface over the harness
/// socket.
public enum SyncEngineError: Error, Sendable, Equatable {
    /// `CatalogDatabase.snapshot(to:)` failed — typically a disk-full or
    /// permissions failure.
    case snapshotFailed(underlying: String)
    /// Drive upload failed after the retry budget was exhausted.
    case uploadFailed(underlying: String)
    /// Drive restore (download) failed.
    case restoreFailed(underlying: String)
    /// The file-id sidecar could not be read or written.
    case fileIdStoreFailed(underlying: String)
    /// No refresh token in the Keychain — caller must authenticate first.
    case notAuthenticated
}
