import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

@MainActor
final class LibraryViewModelTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-ui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempCacheDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

    // MARK: - Fetch / filter / sort

    func testInitialRowsIsEmpty() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    func testReloadExcludesSoftDeleted() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let a = TestFixtures.makeAsset(hash: "aa1")
        let b = TestFixtures.makeAsset(hash: "bb2")
        let c = TestFixtures.makeAsset(hash: "cc3")
        try catalog.insertAsset(a)
        try catalog.insertAsset(b)
        try catalog.insertAsset(c)
        try catalog.deleteAsset(id: b.id)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.reload()

        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertFalse(vm.rows.contains { $0.id == b.id })
    }

    func testReloadSortOrderIsNewestFirstByCaptureDate() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let old = TestFixtures.makeAsset(
            hash: "old",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        let mid = TestFixtures.makeAsset(
            hash: "mid",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        let new = TestFixtures.makeAsset(
            hash: "new",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        // Insert out of order to prove the sort is the view model's job.
        try catalog.insertAsset(mid)
        try catalog.insertAsset(new)
        try catalog.insertAsset(old)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.reload()

        XCTAssertEqual(vm.rows.map(\.id), [new.id, mid.id, old.id])
    }

    func testReloadFallsBackToImportedDateWhenCaptureDateNil() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let scan = TestFixtures.makeAsset(
            hash: "scan",
            captureDate: nil,
            importedDate: Date(timeIntervalSince1970: 3_000_000)
        )
        let dated = TestFixtures.makeAsset(
            hash: "dated",
            captureDate: Date(timeIntervalSince1970: 1_000_000),
            importedDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog.insertAsset(dated)
        try catalog.insertAsset(scan)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.reload()

        // `scan` has no captureDate — the view model must treat its
        // importedDate (newer) as the sort key so it wins over `dated`.
        XCTAssertEqual(vm.rows.map(\.id), [scan.id, dated.id])
    }

    // MARK: - Thumbnail URL resolution

    func testReloadPopulatesThumbnailURLWhenCacheHit() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "abcd1234")
        try catalog.insertAsset(asset)
        try TestFixtures.placeThumbnail(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 200, g: 50, b: 50)
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.reload()

        XCTAssertEqual(vm.rows.count, 1)
        let url = try XCTUnwrap(vm.rows[0].thumbnailURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Thumbnail URL should point at a real file"
        )
    }

    func testReloadThumbnailURLNilWhenCacheMiss() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "deadbeef")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.reload()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertNil(
            vm.rows[0].thumbnailURL,
            "Cache miss must surface nil rather than fabricating a URL"
        )
    }

    // MARK: - Selection

    func testSelectUpdatesSelectedAssetId() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let id = UUID()
        vm.select(id)
        XCTAssertEqual(vm.selectedAssetId, id)

        vm.select(nil)
        XCTAssertNil(vm.selectedAssetId)
    }

    func testReloadClearsSelectionWhenSelectedAssetVanishes() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let a = TestFixtures.makeAsset(hash: "aa")
        try catalog.insertAsset(a)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.reload()
        vm.select(a.id)
        XCTAssertEqual(vm.selectedAssetId, a.id)

        try catalog.deleteAsset(id: a.id)
        vm.reload()
        XCTAssertNil(vm.selectedAssetId)
    }
}
