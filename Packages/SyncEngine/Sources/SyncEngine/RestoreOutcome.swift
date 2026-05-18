import Foundation

/// Outcome of `CatalogPublisher.restoreIfNeeded`. Drives the
/// AppDelegate flow that decides whether to open a freshly downloaded
/// catalog, open an existing local one, or start empty.
public enum RestoreOutcome: Sendable, Equatable {
    /// Catalog was downloaded from Drive and written to `localPath`.
    case restored(driveFileId: String, downloadedBytes: Int64)
    /// User said no to the prompt; local path remains absent.
    case declinedByUser
    /// Drive has no catalog file — first run, nothing to restore.
    case noRemoteCatalog
    /// A local catalog already exists at `localPath`; restore is a
    /// no-op and the caller should just open the existing file.
    case localCatalogPresent
    /// Drive isn't authenticated — caller should fall back to opening
    /// a fresh local catalog as before.
    case notAuthenticated
}

/// Information shown to the user when the restore flow finds a
/// catalog on Drive. The `prompt` callback maps this to an `NSAlert`
/// in production and to a stub in tests.
///
/// `photoCount` may be nil for legacy catalogs published before
/// `appProperties.dimroom_photo_count` was stamped on upload — the
/// prompt UI degrades gracefully to a count-less message in that case.
public struct CatalogRestorePrompt: Sendable, Equatable {
    public let driveFileId: String
    public let sizeBytes: Int64
    public let modifiedTime: Date?
    public let photoCount: Int?

    public init(
        driveFileId: String,
        sizeBytes: Int64,
        modifiedTime: Date?,
        photoCount: Int? = nil
    ) {
        self.driveFileId = driveFileId
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
        self.photoCount = photoCount
    }
}
