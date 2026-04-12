import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

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

    @MainActor
    func testInitialRowsIsEmpty() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        XCTAssertTrue(vm.rows.isEmpty)
    }

    @MainActor
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
        await vm.reloadAndWait()

        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertFalse(vm.rows.contains { $0.id == b.id })
    }

    @MainActor
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
        await vm.reloadAndWait()

        XCTAssertEqual(vm.rows.map(\.id), [new.id, mid.id, old.id])
    }

    @MainActor
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
        await vm.reloadAndWait()

        // `scan` has no captureDate — the view model must treat its
        // importedDate (newer) as the sort key so it wins over `dated`.
        XCTAssertEqual(vm.rows.map(\.id), [scan.id, dated.id])
    }

    // MARK: - Thumbnail URL resolution

    @MainActor
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
        await vm.reloadAndWait()

        XCTAssertEqual(vm.rows.count, 1)
        let url = try XCTUnwrap(vm.rows[0].thumbnailURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Thumbnail URL should point at a real file"
        )
    }

    @MainActor
    func testReloadThumbnailURLNilWhenCacheMiss() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "deadbeef")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertNil(
            vm.rows[0].thumbnailURL,
            "Cache miss must surface nil rather than fabricating a URL"
        )
    }

    // MARK: - Configure (backing store swap)

    @MainActor
    func testConfigureSwitchesBacking() async throws {
        // Start with an empty in-memory catalog (mimics the placeholder).
        let emptyCatalog = try CatalogDatabase.inMemory()
        let emptyStore = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: emptyCatalog, previewStore: emptyStore)
        await vm.reloadAndWait()
        XCTAssertTrue(vm.rows.isEmpty)

        // Create a second catalog with assets (mimics the real catalog).
        let realCatalog = try CatalogDatabase.inMemory()
        let a = TestFixtures.makeAsset(hash: "conf1")
        let b = TestFixtures.makeAsset(hash: "conf2")
        try realCatalog.insertAsset(a)
        try realCatalog.insertAsset(b)

        let realStore = PreviewStore(cacheDirectory: tempCacheDir)

        // The reference must stay the same — SwiftUI's @ObservedObject
        // identity depends on it.
        let identityBefore = ObjectIdentifier(vm)
        vm.configure(catalog: realCatalog, previewStore: realStore)
        await vm.reloadAndWait()
        let identityAfter = ObjectIdentifier(vm)

        XCTAssertEqual(identityBefore, identityAfter)
        XCTAssertEqual(vm.rows.count, 2)
    }

    // MARK: - Selection

    @MainActor
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

    @MainActor
    func testReloadClearsSelectionWhenSelectedAssetVanishes() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let a = TestFixtures.makeAsset(hash: "aa")
        try catalog.insertAsset(a)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        vm.select(a.id)
        XCTAssertEqual(vm.selectedAssetId, a.id)

        try catalog.deleteAsset(id: a.id)
        await vm.reloadAndWait()
        XCTAssertNil(vm.selectedAssetId)
    }
}
