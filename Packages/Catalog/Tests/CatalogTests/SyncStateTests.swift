import XCTest
@testable import Catalog

final class SyncStateTests: XCTestCase {

    private func makeDatabase() throws -> CatalogDatabase {
        try CatalogDatabase.inMemory()
    }

    // MARK: - Drive page token

    func testLoadDrivePageTokenReturnsNilOnFreshCatalog() throws {
        let db = try makeDatabase()
        XCTAssertNil(try db.loadDrivePageToken())
    }

    func testSaveThenLoadDrivePageTokenRoundTrips() throws {
        let db = try makeDatabase()
        try db.saveDrivePageToken("page-token-42")
        XCTAssertEqual(try db.loadDrivePageToken(), "page-token-42")
    }

    func testSaveDrivePageTokenOverwritesExistingValue() throws {
        let db = try makeDatabase()
        try db.saveDrivePageToken("first")
        try db.saveDrivePageToken("second")
        XCTAssertEqual(try db.loadDrivePageToken(), "second")
    }

    // MARK: - Last published catalog modifiedTime

    func testLoadLastPublishedCatalogModifiedTimeReturnsNilFresh() throws {
        let db = try makeDatabase()
        XCTAssertNil(try db.loadLastPublishedCatalogModifiedTime())
    }

    func testSaveAndLoadLastPublishedCatalogModifiedTimeRoundTrips() throws {
        let db = try makeDatabase()
        try db.saveLastPublishedCatalogModifiedTime("2026-05-17T12:34:56.000Z")
        XCTAssertEqual(
            try db.loadLastPublishedCatalogModifiedTime(),
            "2026-05-17T12:34:56.000Z"
        )
    }

    // MARK: - onChange isolation

    func testSavingPageTokenDoesNotFireOnChange() throws {
        let db = try makeDatabase()
        var fired = 0
        db.onChange = { fired += 1 }
        try db.saveDrivePageToken("ignored")
        try db.saveLastPublishedCatalogModifiedTime("2026-01-01T00:00:00Z")
        XCTAssertEqual(
            fired,
            0,
            "sync bookkeeping must not kick the publisher's debouncer"
        )
    }
}
