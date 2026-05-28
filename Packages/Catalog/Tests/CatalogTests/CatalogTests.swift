import XCTest
@testable import Catalog

final class CatalogDatabaseTests: XCTestCase {

    private func makeDatabase() throws -> CatalogDatabase {
        try CatalogDatabase.inMemory()
    }

    private func makeSampleAsset(
        contentHash: String = "abc123",
        sourceType: Asset.SourceType = .digital,
        rating: Int = 0
    ) -> Asset {
        Asset(
            contentHash: contentHash,
            originalFilename: "IMG_0001.CR3",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: sourceType,
            width: 6000,
            height: 4000,
            rawFormat: "CR3",
            bytes: 25_000_000
        )
    }

    // MARK: - Open / In-Memory

    func testOpensInMemoryWithoutError() throws {
        let db = try makeDatabase()
        _ = db // no crash = pass
    }

    // MARK: - Insert + Fetch Round-Trip

    func testInsertAndFetchByHash() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        let fetched = try db.fetchAsset(byHash: "abc123")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, asset.id)
        XCTAssertEqual(fetched?.contentHash, "abc123")
        XCTAssertEqual(fetched?.originalFilename, "IMG_0001.CR3")
        XCTAssertEqual(fetched?.width, 6000)
        XCTAssertEqual(fetched?.height, 4000)
        XCTAssertEqual(fetched?.rawFormat, "CR3")
        XCTAssertEqual(fetched?.bytes, 25_000_000)
        XCTAssertEqual(fetched?.sourceType, .digital)
        XCTAssertEqual(fetched?.rating, 0)
        XCTAssertEqual(fetched?.rotation, 0)
        XCTAssertNil(fetched?.deletedAt)
        XCTAssertNil(fetched?.lensMake)
        XCTAssertNil(fetched?.lensModel)
    }

    func testLensFieldsRoundTrip() throws {
        let db = try makeDatabase()
        let asset = Asset(
            contentHash: "lensrt",
            originalFilename: "IMG_0002.CR3",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .digital,
            sourceDevice: "Canon EOS R6",
            lensMake: "Canon",
            lensModel: "RF 50mm F1.2 L USM",
            width: 6000,
            height: 4000,
            rawFormat: "CR3",
            bytes: 25_000_000
        )
        try db.insertAsset(asset)

        let fetched = try db.fetchAsset(byHash: "lensrt")
        XCTAssertEqual(fetched?.lensMake, "Canon")
        XCTAssertEqual(fetched?.lensModel, "RF 50mm F1.2 L USM")
    }

    // MARK: - Duplicate Hash Rejection

    func testDuplicateHashRejected() throws {
        let db = try makeDatabase()
        let asset1 = makeSampleAsset(contentHash: "dupe")
        let asset2 = makeSampleAsset(contentHash: "dupe")

        try db.insertAsset(asset1)
        XCTAssertThrowsError(try db.insertAsset(asset2))
    }

    // MARK: - Rating Update

    func testUpdateRating() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        try db.updateRating(assetId: asset.id, rating: 5)

        let fetched = try db.fetchAsset(byHash: asset.contentHash)
        XCTAssertEqual(fetched?.rating, 5)
    }

    // MARK: - Rotation Update

    func testUpdateRotation() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        try db.updateRotation(assetId: asset.id, rotation: 90)

        let fetched = try db.fetchAsset(byHash: asset.contentHash)
        XCTAssertEqual(fetched?.rotation, 90)
    }

    func testUpdateRotationStoresArbitraryValue() throws {
        // The catalog is a dumb store — it persists whatever value the
        // caller passes. Normalisation to {0,90,180,270} is the view
        // model's job, not the database's.
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        try db.updateRotation(assetId: asset.id, rotation: 270)
        XCTAssertEqual(try db.fetchAsset(byHash: asset.contentHash)?.rotation, 270)

        try db.updateRotation(assetId: asset.id, rotation: 0)
        XCTAssertEqual(try db.fetchAsset(byHash: asset.contentHash)?.rotation, 0)
    }

    // MARK: - Drive File Id Update

    func testUpdateDriveFileIdSetAndClear() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        try db.updateDriveFileId(assetId: asset.id, driveFileId: "drive-abc")
        XCTAssertEqual(try db.fetchAsset(byHash: asset.contentHash)?.driveFileId, "drive-abc")

        try db.updateDriveFileId(assetId: asset.id, driveFileId: nil)
        XCTAssertNil(try db.fetchAsset(byHash: asset.contentHash)?.driveFileId)
    }

    func testUpdateDriveFileIdForUnknownIdIsNoOp() throws {
        let db = try makeDatabase()
        XCTAssertNoThrow(try db.updateDriveFileId(assetId: UUID(), driveFileId: "ignored"))
    }

    // MARK: - Soft Delete

    func testSoftDelete() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        try db.deleteAsset(id: asset.id)

        // Default fetch excludes deleted
        let defaultResults = try db.fetchAssets()
        XCTAssertTrue(defaultResults.isEmpty)

        // With includeDeleted, it appears
        let allResults = try db.fetchAssets(filter: AssetFilter(includeDeleted: true))
        XCTAssertEqual(allResults.count, 1)
        XCTAssertNotNil(allResults.first?.deletedAt)
    }

    // MARK: - Restore

    func testRestoreAssetClearsDeletedAt() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)
        try db.deleteAsset(id: asset.id)
        XCTAssertNotNil(try db.fetchAssets(filter: AssetFilter(includeDeleted: true)).first?.deletedAt)

        try db.restoreAsset(id: asset.id)

        let live = try db.fetchAssets()
        XCTAssertEqual(live.count, 1)
        XCTAssertNil(live.first?.deletedAt)
    }

    func testRestoreUnknownIdIsNoOp() throws {
        let db = try makeDatabase()
        XCTAssertNoThrow(try db.restoreAsset(id: UUID()))
    }

    // MARK: - Permanent delete

    func testPermanentlyDeleteAssetRemovesRow() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        let removed = try db.permanentlyDeleteAsset(id: asset.id)
        XCTAssertEqual(removed?.id, asset.id)

        // Row is gone — not just hidden.
        let all = try db.fetchAssets(filter: AssetFilter(includeDeleted: true))
        XCTAssertTrue(all.isEmpty)
        XCTAssertNil(try db.fetchAsset(byHash: asset.contentHash))
    }

    func testPermanentlyDeleteUnknownReturnsNil() throws {
        let db = try makeDatabase()
        XCTAssertNil(try db.permanentlyDeleteAsset(id: UUID()))
    }

    // MARK: - Batch delete / restore / permanent

    func testBatchDeleteMarksAllAndSkipsUnknown() throws {
        let db = try makeDatabase()
        let a = makeSampleAsset(contentHash: "bd1")
        let b = makeSampleAsset(contentHash: "bd2")
        let c = makeSampleAsset(contentHash: "bd3")
        try db.insertAsset(a)
        try db.insertAsset(b)
        try db.insertAsset(c)

        let phantom = UUID()
        let updated = try db.deleteAssets(ids: [a.id, b.id, phantom])
        XCTAssertEqual(Set(updated), Set([a.id, b.id]))

        let live = try db.fetchAssets()
        XCTAssertEqual(live.map(\.id), [c.id])
    }

    func testBatchRestoreReturnsIds() throws {
        let db = try makeDatabase()
        let a = makeSampleAsset(contentHash: "br1")
        let b = makeSampleAsset(contentHash: "br2")
        try db.insertAsset(a)
        try db.insertAsset(b)
        try db.deleteAssets(ids: [a.id, b.id])

        let restored = try db.restoreAssets(ids: [a.id, b.id])
        XCTAssertEqual(Set(restored), Set([a.id, b.id]))

        let live = try db.fetchAssets()
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(live.allSatisfy { $0.deletedAt == nil })
    }

    func testBatchPermanentlyDeleteReturnsRemovedAssets() throws {
        let db = try makeDatabase()
        let a = makeSampleAsset(contentHash: "bp1")
        let b = makeSampleAsset(contentHash: "bp2")
        try db.insertAsset(a)
        try db.insertAsset(b)

        let removed = try db.permanentlyDeleteAssets(ids: [a.id, b.id, UUID()])
        XCTAssertEqual(Set(removed.map(\.id)), Set([a.id, b.id]))
        XCTAssertEqual(try db.fetchAssets(filter: AssetFilter(includeDeleted: true)).count, 0)
    }

    // MARK: - Recently Deleted filter

    func testOnlyDeletedFilterReturnsExactlySoftDeletedRows() throws {
        let db = try makeDatabase()
        let live = makeSampleAsset(contentHash: "live")
        let gone = makeSampleAsset(contentHash: "gone")
        try db.insertAsset(live)
        try db.insertAsset(gone)
        try db.deleteAsset(id: gone.id)

        let trash = try db.fetchAssets(filter: AssetFilter(onlyDeleted: true))
        XCTAssertEqual(trash.map(\.id), [gone.id])
        XCTAssertNotNil(trash.first?.deletedAt)
    }

    // MARK: - Filter by Rating

    func testFilterByRating() throws {
        let db = try makeDatabase()

        var a1 = makeSampleAsset(contentHash: "r1")
        a1.rating = 1
        var a2 = makeSampleAsset(contentHash: "r3")
        a2.rating = 3
        var a3 = makeSampleAsset(contentHash: "r5")
        a3.rating = 5

        try db.insertAsset(a1)
        try db.insertAsset(a2)
        try db.insertAsset(a3)

        let filtered = try db.fetchAssets(filter: AssetFilter(rating: 3))
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.rating >= 3 })
    }

    // MARK: - Filter by Source Type

    func testFilterBySourceType() throws {
        let db = try makeDatabase()

        let digital = makeSampleAsset(contentHash: "d1", sourceType: .digital)
        let scan = makeSampleAsset(contentHash: "s1", sourceType: .scan)

        try db.insertAsset(digital)
        try db.insertAsset(scan)

        let digitalResults = try db.fetchAssets(filter: AssetFilter(sourceType: .digital))
        XCTAssertEqual(digitalResults.count, 1)
        XCTAssertEqual(digitalResults.first?.sourceType, .digital)

        let scanResults = try db.fetchAssets(filter: AssetFilter(sourceType: .scan))
        XCTAssertEqual(scanResults.count, 1)
        XCTAssertEqual(scanResults.first?.sourceType, .scan)
    }

    // MARK: - Import Session

    func testInsertImportSession() throws {
        let db = try makeDatabase()
        let session = ImportSession(sourceKind: "folder", sourceDevice: "SD Card", notes: "Test import")
        try db.insertImportSession(session)
        // No crash = pass; we don't expose a fetch method for sessions yet
    }

    // MARK: - Fetch Non-Existent Hash

    func testFetchByHashReturnsNilForMissing() throws {
        let db = try makeDatabase()
        let result = try db.fetchAsset(byHash: "nonexistent")
        XCTAssertNil(result)
    }

    // MARK: - Import Session Id on Asset

    func testMigrationAddsImportSessionId() throws {
        let db = try makeDatabase()
        let session = ImportSession(sourceKind: "folder")
        try db.insertImportSession(session)

        var asset = makeSampleAsset(contentHash: "sess1")
        asset.importSessionId = session.id
        try db.insertAsset(asset)

        let fetched = try db.fetchAsset(byHash: "sess1")
        XCTAssertEqual(fetched?.importSessionId, session.id)
    }

    func testAssetImportSessionIdDefaultsToNil() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset(contentHash: "nosess")
        try db.insertAsset(asset)

        let fetched = try db.fetchAsset(byHash: "nosess")
        XCTAssertNil(fetched?.importSessionId)
    }

    // MARK: - countAssets

    func testCountAssetsExcludesSoftDeleted() throws {
        let db = try makeDatabase()
        let liveIds = (0..<3).map { _ in UUID() }
        for (i, id) in liveIds.enumerated() {
            var a = makeSampleAsset(contentHash: "live-\(i)")
            a.id = id
            try db.insertAsset(a)
        }
        let deletedId = UUID()
        var deleted = makeSampleAsset(contentHash: "to-delete")
        deleted.id = deletedId
        try db.insertAsset(deleted)
        try db.deleteAsset(id: deletedId)

        XCTAssertEqual(try db.countAssets(), 3)
    }

    // MARK: - Filter by Import Session

    func testFetchAssetsFilteredByImportSessionId() throws {
        let db = try makeDatabase()
        let s1 = ImportSession(sourceKind: "folder")
        let s2 = ImportSession(sourceKind: "folder")
        try db.insertImportSession(s1)
        try db.insertImportSession(s2)

        var a1 = makeSampleAsset(contentHash: "is1")
        a1.importSessionId = s1.id
        var a2 = makeSampleAsset(contentHash: "is2")
        a2.importSessionId = s1.id
        var a3 = makeSampleAsset(contentHash: "is3")
        a3.importSessionId = s2.id

        try db.insertAsset(a1)
        try db.insertAsset(a2)
        try db.insertAsset(a3)

        let filtered = try db.fetchAssets(filter: AssetFilter(importSessionId: s1.id))
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { $0.importSessionId == s1.id })
    }

    // MARK: - Fetch Import Sessions

    func testFetchImportSessionsReturnsRecentWithCounts() throws {
        let db = try makeDatabase()
        let s1 = ImportSession(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceKind: "folder",
            sourceDevice: "Canon EOS R6"
        )
        let s2 = ImportSession(
            startedAt: Date(timeIntervalSince1970: 2_000_000),
            sourceKind: "folder",
            sourceDevice: "Pixii"
        )
        let s3 = ImportSession(
            startedAt: Date(timeIntervalSince1970: 3_000_000),
            sourceKind: "folder"
        )
        try db.insertImportSession(s1)
        try db.insertImportSession(s2)
        try db.insertImportSession(s3)

        // s1: 1 asset, s2: 2 assets, s3: 1 asset
        var a1 = makeSampleAsset(contentHash: "fs1")
        a1.importSessionId = s1.id
        var a2 = makeSampleAsset(contentHash: "fs2")
        a2.importSessionId = s2.id
        var a3 = makeSampleAsset(contentHash: "fs3")
        a3.importSessionId = s2.id
        var a4 = makeSampleAsset(contentHash: "fs4")
        a4.importSessionId = s3.id

        try db.insertAsset(a1)
        try db.insertAsset(a2)
        try db.insertAsset(a3)
        try db.insertAsset(a4)

        let sessions = try db.fetchImportSessions()
        XCTAssertEqual(sessions.count, 3)
        // Most recent first
        XCTAssertEqual(sessions[0].id, s3.id)
        XCTAssertEqual(sessions[1].id, s2.id)
        XCTAssertEqual(sessions[2].id, s1.id)
        // Correct counts
        XCTAssertEqual(sessions[0].assetCount, 1)
        XCTAssertEqual(sessions[1].assetCount, 2)
        XCTAssertEqual(sessions[2].assetCount, 1)
    }

    func testFetchImportSessionsTrimming() throws {
        let db = try makeDatabase()
        // Insert 25 sessions each with 1 asset
        for i in 0..<25 {
            let s = ImportSession(
                startedAt: Date(timeIntervalSince1970: Double(i) * 1000),
                sourceKind: "folder"
            )
            try db.insertImportSession(s)
            var a = makeSampleAsset(contentHash: "trim\(i)")
            a.importSessionId = s.id
            try db.insertAsset(a)
        }

        let sessions = try db.fetchImportSessions()
        XCTAssertEqual(sessions.count, 20)
    }

    func testFetchImportSessionsExcludesEmptySessions() throws {
        let db = try makeDatabase()
        let s1 = ImportSession(sourceKind: "folder")
        try db.insertImportSession(s1)
        // No assets linked → s1 should not appear
        let sessions = try db.fetchImportSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    // MARK: - Import Session Display Name

    func testImportSessionDisplayNameWithDevice() throws {
        let session = ImportSession(
            startedAt: Date(timeIntervalSince1970: 1_712_870_400), // 12 Apr 2024
            sourceKind: "folder",
            sourceDevice: "Pixii Camera (A3410)"
        )
        let name = session.displayName()
        XCTAssertTrue(name.hasPrefix("Pixii Camera (A3410) — "))
        XCTAssertTrue(name.contains("2024"))
    }

    func testImportSessionDisplayNameFallsBackToFolder() throws {
        let session = ImportSession(
            startedAt: Date(timeIntervalSince1970: 1_712_870_400),
            sourceKind: "folder",
            sourceDevice: nil
        )
        let name = session.displayName()
        XCTAssertTrue(name.hasPrefix("Folder — "))
    }

    // MARK: - Update Import Session Source Device

    func testUpdateImportSessionSourceDevice() throws {
        let db = try makeDatabase()
        let session = ImportSession(sourceKind: "folder", sourceDevice: nil)
        try db.insertImportSession(session)

        try db.updateImportSessionSourceDevice(id: session.id, sourceDevice: "Canon EOS R6")

        // Verify by inserting an asset and checking session display name
        var asset = makeSampleAsset(contentHash: "devup")
        asset.importSessionId = session.id
        try db.insertAsset(asset)
        let sessions = try db.fetchImportSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].displayName.contains("Canon EOS R6"))
    }

    // MARK: - onChange notification

    func testOnChangeFiresOncePerWriterAcrossAPIs() throws {
        let db = try makeDatabase()
        let counter = CallCounter()
        db.onChange = { counter.increment() }

        // Build up enough state to exercise every writer path.
        let asset = makeSampleAsset(contentHash: "oc1")
        try db.insertAsset(asset)
        XCTAssertEqual(counter.value, 1)

        let session = ImportSession(sourceKind: "folder")
        try db.insertImportSession(session)
        XCTAssertEqual(counter.value, 2)

        try db.updateImportSessionSourceDevice(id: session.id, sourceDevice: "Canon")
        XCTAssertEqual(counter.value, 3)

        try db.updateRating(assetId: asset.id, rating: 4)
        XCTAssertEqual(counter.value, 4)

        try db.updateRotation(assetId: asset.id, rotation: 90)
        XCTAssertEqual(counter.value, 5)

        try db.updateLocalPath(assetId: asset.id, path: "/tmp/local.jpg")
        XCTAssertEqual(counter.value, 6)

        try db.updateDriveFileId(assetId: asset.id, driveFileId: "drive-1")
        XCTAssertEqual(counter.value, 7)

        _ = try db.saveEditState(EditState(), for: asset.id)
        XCTAssertEqual(counter.value, 8)

        try db.deleteAsset(id: asset.id)
        XCTAssertEqual(counter.value, 9)

        try db.restoreAsset(id: asset.id)
        XCTAssertEqual(counter.value, 10)

        // Batch operations fire once per call, not once per row.
        let b = makeSampleAsset(contentHash: "oc2")
        let c = makeSampleAsset(contentHash: "oc3")
        try db.insertAsset(b)
        try db.insertAsset(c)
        XCTAssertEqual(counter.value, 12)

        try db.deleteAssets(ids: [b.id, c.id])
        XCTAssertEqual(counter.value, 13)

        try db.restoreAssets(ids: [b.id, c.id])
        XCTAssertEqual(counter.value, 14)

        try db.permanentlyDeleteAssets(ids: [b.id, c.id])
        XCTAssertEqual(counter.value, 15)

        _ = try db.permanentlyDeleteAsset(id: asset.id)
        XCTAssertEqual(counter.value, 16)
    }

    func testOnChangeDoesNotFireWhenNothingChanges() throws {
        let db = try makeDatabase()
        let counter = CallCounter()
        db.onChange = { counter.increment() }

        // Unknown ids — nothing actually written.
        try db.updateRating(assetId: UUID(), rating: 3)
        try db.updateRotation(assetId: UUID(), rotation: 0)
        try db.updateLocalPath(assetId: UUID(), path: "/x")
        try db.updateDriveFileId(assetId: UUID(), driveFileId: "x")
        try db.deleteAsset(id: UUID())
        try db.restoreAsset(id: UUID())
        _ = try db.deleteAssets(ids: [UUID(), UUID()])
        _ = try db.restoreAssets(ids: [UUID()])
        _ = try db.permanentlyDeleteAsset(id: UUID())
        _ = try db.permanentlyDeleteAssets(ids: [UUID()])

        XCTAssertEqual(counter.value, 0)
    }

    // MARK: - snapshot(to:)

    func testSnapshotProducesOpenableEquivalentDatabase() throws {
        let db = try makeDatabase()
        let a = makeSampleAsset(contentHash: "snap-a")
        let b = makeSampleAsset(contentHash: "snap-b")
        try db.insertAsset(a)
        try db.insertAsset(b)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-snapshot-\(UUID().uuidString)")
            .appendingPathComponent("snap.sqlite")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try db.snapshot(to: tmp.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let restored = try CatalogDatabase(path: tmp.path)
        let assets = try restored.fetchAssets().sorted { $0.contentHash < $1.contentHash }
        XCTAssertEqual(assets.map(\.contentHash), ["snap-a", "snap-b"])
    }

    func testSnapshotOverwritesExistingDestination() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset(contentHash: "ow")
        try db.insertAsset(asset)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-snapshot-\(UUID().uuidString)")
            .appendingPathComponent("snap.sqlite")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try db.snapshot(to: tmp.path)
        let firstSize = try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(firstSize, 0)

        // Second snapshot must replace rather than fail.
        try db.snapshot(to: tmp.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testSnapshotCreatesParentDirectory() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset(contentHash: "parent")
        try db.insertAsset(asset)

        let nested = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-snapshot-\(UUID().uuidString)")
            .appendingPathComponent("nested/deep")
            .appendingPathComponent("snap.sqlite")
        defer {
            try? FileManager.default.removeItem(
                at: nested.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        try db.snapshot(to: nested.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    // MARK: - path property

    func testInMemoryPathIsSentinel() throws {
        let db = try CatalogDatabase.inMemory()
        XCTAssertEqual(db.path, ":memory:")
    }

    func testOpenedPathIsExposed() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-path-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let db = try CatalogDatabase(path: tmp.path)
        XCTAssertEqual(db.path, tmp.path)
    }
}

/// Thread-safe counter used by `onChange` tests so the callback can be
/// invoked from any GRDB write queue without confusing XCTest.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
