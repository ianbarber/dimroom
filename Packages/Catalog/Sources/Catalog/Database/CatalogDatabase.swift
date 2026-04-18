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

    /// O(1) lookup by primary key, used on hot paths (originals fetch,
    /// eviction bookkeeping) where scanning `fetchAssets(filter:)` would
    /// be linear in catalog size.
    public func fetchAsset(id: UUID) throws -> Asset? {
        try dbQueue.read { db in
            try Asset.fetchOne(db, key: id)
        }
    }

    public func fetchAssets(filter: AssetFilter = AssetFilter()) throws -> [Asset] {
        try dbQueue.read { db in
            var request = Asset.all()

            if filter.onlyDeleted {
                request = request.filter(Column("deletedAt") != nil)
            } else if !filter.includeDeleted {
                request = request.filter(Column("deletedAt") == nil)
            }
            if let rating = filter.rating {
                request = request.filter(Column("rating") >= rating)
            }
            if let sourceType = filter.sourceType {
                request = request.filter(Column("sourceType") == sourceType)
            }
            if let sessionId = filter.importSessionId {
                request = request.filter(Column("importSessionId") == sessionId)
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

    public func updateRotation(assetId: UUID, rotation: Int) throws {
        try dbQueue.write { db in
            if var asset = try Asset.fetchOne(db, key: assetId) {
                asset.rotation = rotation
                try asset.update(db)
            }
        }
    }

    /// Set `Asset.localPath` for the given asset. Passing `nil` clears it,
    /// which is what the originals cache does on eviction so stale paths
    /// never serve a deleted file.
    public func updateLocalPath(assetId: UUID, path: String?) throws {
        try dbQueue.write { db in
            if var asset = try Asset.fetchOne(db, key: assetId) {
                asset.localPath = path
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

    /// Soft-delete multiple assets in a single write transaction. Unknown
    /// ids are skipped. Returns the set of ids that were actually marked
    /// deleted (i.e. existed in the catalog at write time).
    @discardableResult
    public func deleteAssets(ids: [UUID]) throws -> [UUID] {
        try dbQueue.write { db in
            let now = Date()
            var updated: [UUID] = []
            for id in ids {
                if var asset = try Asset.fetchOne(db, key: id) {
                    asset.deletedAt = now
                    try asset.update(db)
                    updated.append(id)
                }
            }
            return updated
        }
    }

    /// Inverse of `deleteAsset`: clears `deletedAt` so the asset shows up
    /// in default queries again. Used by the undo stack to reverse a
    /// soft-delete.
    public func restoreAsset(id: UUID) throws {
        try dbQueue.write { db in
            if var asset = try Asset.fetchOne(db, key: id) {
                asset.deletedAt = nil
                try asset.update(db)
            }
        }
    }

    /// Clear `deletedAt` for multiple assets in a single write
    /// transaction. Returns the ids that were actually restored.
    @discardableResult
    public func restoreAssets(ids: [UUID]) throws -> [UUID] {
        try dbQueue.write { db in
            var updated: [UUID] = []
            for id in ids {
                if var asset = try Asset.fetchOne(db, key: id) {
                    asset.deletedAt = nil
                    try asset.update(db)
                    updated.append(id)
                }
            }
            return updated
        }
    }

    /// Permanently remove an asset row from the catalog. Returns the
    /// `Asset` value that was deleted so callers can clean up cached
    /// previews and local originals.
    @discardableResult
    public func permanentlyDeleteAsset(id: UUID) throws -> Asset? {
        try dbQueue.write { db in
            guard let asset = try Asset.fetchOne(db, key: id) else { return nil }
            try asset.delete(db)
            return asset
        }
    }

    /// Permanently remove multiple asset rows in a single write
    /// transaction. Returns the `Asset` values that were deleted.
    @discardableResult
    public func permanentlyDeleteAssets(ids: [UUID]) throws -> [Asset] {
        try dbQueue.write { db in
            var removed: [Asset] = []
            for id in ids {
                if let asset = try Asset.fetchOne(db, key: id) {
                    try asset.delete(db)
                    removed.append(asset)
                }
            }
            return removed
        }
    }

    // MARK: - Import Sessions

    public func insertImportSession(_ session: ImportSession) throws {
        try dbQueue.write { db in
            try session.insert(db)
        }
    }

    /// Returns the most recent import sessions that have at least one
    /// linked asset, ordered newest-first, capped at `limit`.
    public func fetchImportSessions(limit: Int = 20) throws -> [ImportSessionSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.startedAt, s.sourceKind, s.sourceDevice,
                       COUNT(a.id) AS assetCount
                FROM import_sessions s
                JOIN assets a ON a.importSessionId = s.id AND a.deletedAt IS NULL
                GROUP BY s.id
                ORDER BY s.startedAt DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                let session = ImportSession(
                    id: row["id"],
                    startedAt: row["startedAt"],
                    sourceKind: row["sourceKind"],
                    sourceDevice: row["sourceDevice"]
                )
                return ImportSessionSummary(
                    id: session.id,
                    displayName: session.displayName(),
                    assetCount: row["assetCount"],
                    startedAt: session.startedAt
                )
            }
        }
    }

    public func updateImportSessionSourceDevice(id: UUID, sourceDevice: String) throws {
        try dbQueue.write { db in
            if var session = try ImportSession.fetchOne(db, key: id) {
                session.sourceDevice = sourceDevice
                try session.update(db)
            }
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
