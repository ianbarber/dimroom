import Foundation

/// Value type the uploader consumes for a single asset. Exists so
/// `DriveClient` stays independent of `Catalog`: the UI / app layer
/// translates from `Asset` into this shape before handing it off.
public struct DriveAssetRef: Sendable, Equatable {
    public var assetId: UUID
    public var localPath: URL
    public var contentHash: String
    public var originalFilename: String
    public var bytes: Int64
    public var captureDate: Date?
    public var importedDate: Date
    public var sourceType: DriveSourceType
    public var mimeType: String

    public init(
        assetId: UUID,
        localPath: URL,
        contentHash: String,
        originalFilename: String,
        bytes: Int64,
        captureDate: Date?,
        importedDate: Date,
        sourceType: DriveSourceType,
        mimeType: String
    ) {
        self.assetId = assetId
        self.localPath = localPath
        self.contentHash = contentHash
        self.originalFilename = originalFilename
        self.bytes = bytes
        self.captureDate = captureDate
        self.importedDate = importedDate
        self.sourceType = sourceType
        self.mimeType = mimeType
    }
}
