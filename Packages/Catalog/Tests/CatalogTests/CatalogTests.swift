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
}
