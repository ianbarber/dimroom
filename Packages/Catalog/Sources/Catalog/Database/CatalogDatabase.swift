import Foundation
import GRDB

public final class CatalogDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        var migrator = DatabaseMigrator()
        CatalogMigrations.registerAll(in: &migrator)
        try migrator.migrate(dbQueue)
    }

    public convenience init(path: String) throws {
        let dbQueue = try DatabaseQueue(path: path)
        try self.init(dbQueue: dbQueue)
    }

    public static func inMemory() throws -> CatalogDatabase {
        let dbQueue = try DatabaseQueue()
        return try CatalogDatabase(dbQueue: dbQueue)
    }

    // MARK: - Assets

    public func insertAsset(_ asset: Asset) throws {
        try dbQueue.write { db in
            try asset.insert(db)
        }
    }

    public func fetchAsset(byHash hash: String) throws -> Asset? {
        try dbQueue.read { db in
            try Asset.filter(Column("contentHash") == hash).fetchOne(db)
        }
    }

    public func fetchAssets(filter: AssetFilter = AssetFilter()) throws -> [Asset] {
        try dbQueue.read { db in
            var request = Asset.all()

            if !filter.includeDeleted {
                request = request.filter(Column("deletedAt") == nil)
            }
            if let rating = filter.rating {
                request = request.filter(Column("rating") >= rating)
            }
            if let sourceType = filter.sourceType {
                request = request.filter(Column("sourceType") == sourceType)
            }

            return try request.fetchAll(db)
        }
    }

    public func updateRating(assetId: UUID, rating: Int) throws {
        try dbQueue.write { db in
            if var asset = try Asset.fetchOne(db, key: assetId) {
                asset.rating = rating
                try asset.update(db)
            }
        }
    }

    public func deleteAsset(id: UUID) throws {
        try dbQueue.write { db in
            if var asset = try Asset.fetchOne(db, key: id) {
                asset.deletedAt = Date()
                try asset.update(db)
            }
        }
    }

    // MARK: - Import Sessions

    public func insertImportSession(_ session: ImportSession) throws {
        try dbQueue.write { db in
            try session.insert(db)
        }
    }

    // MARK: - Edit States

    /// Inserts a new versioned edit state for the given asset. Returns the version number.
    @discardableResult
    public func saveEditState(_ state: EditState, for assetId: UUID) throws -> Int {
        try dbQueue.write { db in
            let maxVersion = try Int.fetchOne(
                db,
                sql: "SELECT MAX(version) FROM edit_states WHERE assetId = ?",
                arguments: [assetId]
            ) ?? 0
            let newVersion = maxVersion + 1

            let record = EditStateRecord(
                id: UUID(),
                assetId: assetId,
                version: newVersion,
                state: try EditStateRecord.encode(state),
                createdAt: Date()
            )
            try record.insert(db)
            return newVersion
        }
    }

    /// Returns the most recent edit state for the given asset, or nil if no edits exist.
    public func latestEditState(for assetId: UUID) throws -> EditState? {
        try dbQueue.read { db in
            let record = try EditStateRecord
                .filter(Column("assetId") == assetId)
                .order(Column("version").desc)
                .fetchOne(db)
            return try record?.decodeState()
        }
    }

    /// Returns all edit state versions for the given asset, ordered newest-first.
    public func editHistory(for assetId: UUID) throws -> [(version: Int, state: EditState, createdAt: Date)] {
        try dbQueue.read { db in
            let records = try EditStateRecord
                .filter(Column("assetId") == assetId)
                .order(Column("version").desc)
                .fetchAll(db)
            return try records.map { record in
                (version: record.version, state: try record.decodeState(), createdAt: record.createdAt)
            }
        }
    }
}
