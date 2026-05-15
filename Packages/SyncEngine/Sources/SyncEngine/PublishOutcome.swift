import Foundation

/// Result of a single catalog publish. Returned from
/// `CatalogPublisher.publishNow()` and surfaced over the harness socket
/// so flows can assert on the upload shape.
public struct PublishOutcome: Sendable, Equatable {
    public let driveFileId: String
    public let uploadedBytes: Int64
    public let duration: Duration
    /// `true` when the catalog was created on Drive (no cached file id),
    /// `false` when an existing file was updated.
    public let wasCreate: Bool

    public init(driveFileId: String, uploadedBytes: Int64, duration: Duration, wasCreate: Bool) {
        self.driveFileId = driveFileId
        self.uploadedBytes = uploadedBytes
        self.duration = duration
        self.wasCreate = wasCreate
    }
}

/// Returned by `CatalogUploading.upload(...)`. Distinct from
/// `PublishOutcome` so the protocol contract is independent of the
/// publisher's view (timing, create-vs-update).
public struct CatalogUploadResult: Sendable, Equatable {
    public let driveFileId: String
    public let uploadedBytes: Int64
    public let wasCreate: Bool

    public init(driveFileId: String, uploadedBytes: Int64, wasCreate: Bool) {
        self.driveFileId = driveFileId
        self.uploadedBytes = uploadedBytes
        self.wasCreate = wasCreate
    }
}

/// Reference to a catalog file discovered on Drive. Used during restore
/// so the prompt can show "found a 4 MB catalog modified 3 days ago".
public struct DriveCatalogRef: Sendable, Equatable {
    public let driveFileId: String
    public let sizeBytes: Int64
    public let modifiedTime: Date?

    public init(driveFileId: String, sizeBytes: Int64, modifiedTime: Date?) {
        self.driveFileId = driveFileId
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
    }
}
