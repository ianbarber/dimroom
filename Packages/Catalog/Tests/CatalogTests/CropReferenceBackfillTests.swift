import CoreGraphics
import GRDB
import XCTest
@testable import Catalog

/// Tests for the `006-backfillCropReferenceSize` migration (#352): legacy
/// already-cropped rows (`cropRect != nil`, `cropReferenceSize == nil`)
/// must be stamped with the reconstructed authoring preview size so they
/// export at full-resolution framing without a manual re-commit.
final class CropReferenceBackfillTests: XCTestCase {

    // MARK: - Size reconstruction (pure)

    func testLandscapeDownscaleFitsLongEdgeTo2048() {
        // 6000×4000 long edge 6000 → scale 2048/6000, short edge rounds to
        // 1365 — the same reference a re-commit records (see #351's
        // CropResolutionRenderTests).
        let size = legacyCropReferenceSize(width: 6000, height: 4000, rotation: 0)
        XCTAssertEqual(size, CGSize(width: 2048, height: 1365))
    }

    func testNoUpscaleWhenLongEdgeBelowCeiling() {
        // Long edge already ≤ 2048: `scale` clamps to 1.0, so the rotated
        // natural size passes through unchanged.
        let size = legacyCropReferenceSize(width: 1600, height: 1200, rotation: 0)
        XCTAssertEqual(size, CGSize(width: 1600, height: 1200))
    }

    func testRotation90SwapsAspect() {
        // A quarter turn swaps the axes before the 2048 fit, exactly as
        // PreviewStore.applyRotation does — so the reference is portrait.
        let size = legacyCropReferenceSize(width: 6000, height: 4000, rotation: 90)
        XCTAssertEqual(size, CGSize(width: 1365, height: 2048))
    }

    func testRotation270SwapsAspect() {
        let size = legacyCropReferenceSize(width: 6000, height: 4000, rotation: 270)
        XCTAssertEqual(size, CGSize(width: 1365, height: 2048))
    }

    func testRotation180DoesNotSwap() {
        let size = legacyCropReferenceSize(width: 6000, height: 4000, rotation: 180)
        XCTAssertEqual(size, CGSize(width: 2048, height: 1365))
    }

    func testNegativeRotationNormalises() {
        // -90 normalises to 270 → still a swap.
        let size = legacyCropReferenceSize(width: 6000, height: 4000, rotation: -90)
        XCTAssertEqual(size, CGSize(width: 1365, height: 2048))
    }

    func testDegenerateDimensionsReturnNil() {
        XCTAssertNil(legacyCropReferenceSize(width: 0, height: 0, rotation: 0))
        XCTAssertNil(legacyCropReferenceSize(width: 0, height: 100, rotation: 0))
        XCTAssertNil(legacyCropReferenceSize(width: 100, height: 0, rotation: 0))
    }

    // MARK: - Backfill path (DB)

    func testBackfillSetsReferenceSizeOnLegacyRow() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(cropRect: CGRect(x: 100, y: 50, width: 1000, height: 700))
        )

        // Precondition: this really is a legacy row.
        XCTAssertNil(try latestState(in: dbQueue, assetId: assetId).cropReferenceSize)

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }

        let backfilled = try latestState(in: dbQueue, assetId: assetId)
        XCTAssertEqual(backfilled.cropReferenceSize, CGSize(width: 2048, height: 1365))
        // The crop rect itself is untouched.
        XCTAssertEqual(backfilled.cropRect, CGRect(x: 100, y: 50, width: 1000, height: 700))
    }

    func testBackfillUsesRotatedReferenceForPortraitAsset() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 90)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(cropRect: CGRect(x: 10, y: 20, width: 300, height: 400))
        )

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }

        let backfilled = try latestState(in: dbQueue, assetId: assetId)
        XCTAssertEqual(backfilled.cropReferenceSize, CGSize(width: 1365, height: 2048))
    }

    // MARK: - Idempotence / non-clobber

    func testBackfillLeavesExistingReferenceSizeUntouched() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        // A row authored *after* #351 already carries a reference size that
        // differs from what reconstruction would produce. The backfill
        // must not clobber it.
        let existing = CGSize(width: 1024, height: 683)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(
                cropRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                cropReferenceSize: existing
            )
        )

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }

        XCTAssertEqual(try latestState(in: dbQueue, assetId: assetId).cropReferenceSize, existing)
    }

    func testBackfillSkipsRowsWithoutCrop() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(exposure: 0.5)
        )

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }

        let state = try latestState(in: dbQueue, assetId: assetId)
        XCTAssertNil(state.cropRect)
        XCTAssertNil(state.cropReferenceSize)
    }

    func testBackfillIsIdempotent() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(cropRect: CGRect(x: 100, y: 50, width: 1000, height: 700))
        )

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }
        let first = try latestState(in: dbQueue, assetId: assetId)
        // A second pass must change nothing — the guard skips rows that
        // already carry a reference size.
        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }
        let second = try latestState(in: dbQueue, assetId: assetId)

        XCTAssertEqual(first.cropReferenceSize, CGSize(width: 2048, height: 1365))
        XCTAssertEqual(second.cropReferenceSize, first.cropReferenceSize)
    }

    // MARK: - No version churn (acceptance criterion 2)

    func testBackfillCreatesNoNewVersions() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(cropRect: CGRect(x: 100, y: 50, width: 1000, height: 700))
        )

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }

        let records = try dbQueue.read { db in
            try EditStateRecord
                .filter(Column("assetId") == assetId)
                .order(Column("version"))
                .fetchAll(db)
        }
        // Still exactly one row, still version 1 — an UPDATE, not an INSERT.
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.version, 1)
    }

    func testBackfillStampsEveryVersion() throws {
        let dbQueue = try makeMigratedQueue()
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        for version in 1...3 {
            try insertEditState(
                in: dbQueue,
                assetId: assetId,
                version: version,
                state: EditState(cropRect: CGRect(x: 0, y: 0, width: 1000, height: 700))
            )
        }

        try dbQueue.write { db in try backfillCropReferenceSizes(in: db) }

        let states = try dbQueue.read { db in
            try EditStateRecord
                .filter(Column("assetId") == assetId)
                .fetchAll(db)
                .map { try $0.decodeState() }
        }
        XCTAssertEqual(states.count, 3)
        for state in states {
            XCTAssertEqual(state.cropReferenceSize, CGSize(width: 2048, height: 1365))
        }
    }

    // MARK: - Migration end-to-end

    func testMigration006BackfillsLegacyRowsAutomatically() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        CatalogMigrations.registerAll(in: &migrator)

        // Migrate only up to the pre-backfill schema, then seed a legacy
        // cropped row the way a pre-#351 binary would have written it.
        try migrator.migrate(dbQueue, upTo: "005-addLensFieldsToAssets")
        let assetId = try insertAsset(in: dbQueue, width: 6000, height: 4000, rotation: 0)
        try insertEditState(
            in: dbQueue,
            assetId: assetId,
            version: 1,
            state: EditState(cropRect: CGRect(x: 100, y: 50, width: 1000, height: 700))
        )

        // Running the remaining migrations fires 006.
        try migrator.migrate(dbQueue)

        XCTAssertEqual(
            try latestState(in: dbQueue, assetId: assetId).cropReferenceSize,
            CGSize(width: 2048, height: 1365)
        )
    }

    // MARK: - Helpers

    private func makeMigratedQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        CatalogMigrations.registerAll(in: &migrator)
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    @discardableResult
    private func insertAsset(
        in dbQueue: DatabaseQueue,
        width: Int,
        height: Int,
        rotation: Int
    ) throws -> UUID {
        let asset = Asset(
            contentHash: UUID().uuidString,
            originalFilename: "IMG.CR3",
            sourceType: .digital,
            width: width,
            height: height,
            rotation: rotation,
            bytes: 1_000
        )
        try dbQueue.write { db in try asset.insert(db) }
        return asset.id
    }

    private func insertEditState(
        in dbQueue: DatabaseQueue,
        assetId: UUID,
        version: Int,
        state: EditState
    ) throws {
        let record = EditStateRecord(
            id: UUID(),
            assetId: assetId,
            version: version,
            state: try EditStateRecord.encode(state),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dbQueue.write { db in try record.insert(db) }
    }

    private func latestState(in dbQueue: DatabaseQueue, assetId: UUID) throws -> EditState {
        try dbQueue.read { db in
            let record = try EditStateRecord
                .filter(Column("assetId") == assetId)
                .order(Column("version").desc)
                .fetchOne(db)
            return try XCTUnwrap(record).decodeState()
        }
    }
}
