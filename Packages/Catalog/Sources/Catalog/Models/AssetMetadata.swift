import Foundation
import GRDB

public struct AssetMetadata: Codable, Sendable {
    public var assetId: UUID
    public var exifJSON: String

    public init(assetId: UUID, exifJSON: String) {
        self.assetId = assetId
        self.exifJSON = exifJSON
    }
}

extension AssetMetadata: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "asset_metadata" }
}
