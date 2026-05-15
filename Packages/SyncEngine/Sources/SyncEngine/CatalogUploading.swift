import Foundation

/// Drive-side contract for catalog publish. `CatalogPublisher` depends
/// on this rather than a concrete uploader so unit tests can substitute
/// an in-memory stub without standing up HTTP fixtures.
public protocol CatalogUploading: Sendable {
    /// Upload the SQLite snapshot at `snapshotPath` to Drive. When
    /// `existingFileId` is non-nil the implementation should PATCH that
    /// file; otherwise create a new file in the catalog folder.
    func upload(snapshotPath: String, existingFileId: String?) async throws -> CatalogUploadResult

    /// Look up the current catalog on Drive (if any). Used at startup
    /// to offer a restore.
    func findExistingCatalog() async throws -> DriveCatalogRef?

    /// Download `fileId` to `localPath`. Returns the byte count written
    /// so tests / callers can confirm the file was actually fetched.
    func download(fileId: String, to localPath: String) async throws -> Int64
}
