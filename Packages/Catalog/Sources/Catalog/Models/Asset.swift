import Foundation
import GRDB

public struct Asset: Identifiable, Codable, Sendable {
    public var id: UUID
    public var contentHash: String
    public var originalFilename: String
    public var captureDate: Date?
    public var importedDate: Date
    public var sourceType: SourceType
    public var sourceDevice: String?
    public var width: Int
    public var height: Int
    public var rawFormat: String?
    public var rating: Int
    public var rotation: Int
    public var driveFileId: String?
    public var localPath: String?
    public var bytes: Int64
    public var deletedAt: Date?
    public var importSessionId: UUID?

    public enum SourceType: String, Codable, Sendable, DatabaseValueConvertible {
        case digital
        case scan
    }

    public init(
        id: UUID = UUID(),
        contentHash: String,
        originalFilename: String,
        captureDate: Date? = nil,
        importedDate: Date = Date(),
        sourceType: SourceType,
        sourceDevice: String? = nil,
        width: Int,
        height: Int,
        rawFormat: String? = nil,
        rating: Int = 0,
        rotation: Int = 0,
        driveFileId: String? = nil,
        localPath: String? = nil,
        bytes: Int64,
        deletedAt: Date? = nil,
        importSessionId: UUID? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.originalFilename = originalFilename
        self.captureDate = captureDate
        self.importedDate = importedDate
        self.sourceType = sourceType
        self.sourceDevice = sourceDevice
        self.width = width
        self.height = height
        self.rawFormat = rawFormat
        self.rating = rating
        self.rotation = rotation
        self.driveFileId = driveFileId
        self.localPath = localPath
        self.bytes = bytes
        self.deletedAt = deletedAt
        self.importSessionId = importSessionId
    }
}

extension Asset: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "assets" }
}
