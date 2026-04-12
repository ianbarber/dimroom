import GRDB

enum CatalogMigrations {
    static func registerAll(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("001-createCoreTables") { db in
            try db.create(table: "import_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("startedAt", .datetime).notNull()
                t.column("sourceKind", .text).notNull()
                t.column("sourceDevice", .text)
                t.column("notes", .text)
            }

            try db.create(table: "assets") { t in
                t.column("id", .text).primaryKey()
                t.column("contentHash", .text).notNull().unique()
                t.column("originalFilename", .text).notNull()
                t.column("captureDate", .datetime)
                t.column("importedDate", .datetime).notNull()
                t.column("sourceType", .text).notNull()
                t.column("sourceDevice", .text)
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("rawFormat", .text)
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("rotation", .integer).notNull().defaults(to: 0)
                t.column("driveFileId", .text)
                t.column("localPath", .text)
                t.column("bytes", .integer).notNull()
                t.column("deletedAt", .datetime)
            }

            try db.create(index: "assets_on_captureDate", on: "assets", columns: ["captureDate"])

            try db.create(table: "asset_metadata") { t in
                t.column("assetId", .text)
                    .notNull()
                    .references("assets", onDelete: .cascade)
                t.column("exifJSON", .text).notNull()
                t.primaryKey(["assetId"])
            }
        }

        migrator.registerMigration("002-createEditStates") { db in
            try db.create(table: "edit_states") { t in
                t.column("id", .text).primaryKey()
                t.column("assetId", .text)
                    .notNull()
                    .references("assets", onDelete: .cascade)
                t.column("version", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["assetId", "version"])
            }
        }
    }
}
