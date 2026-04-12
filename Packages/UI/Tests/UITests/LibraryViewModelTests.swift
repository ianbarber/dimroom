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

    // MARK: - Rating + filter

    /// Insert three assets at ratings 1/3/5 and check that
    /// `setMinRating(3)` drops the 1-star row from `rows`.
    @MainActor
    func testSetMinRatingFiltersRows() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var one = TestFixtures.makeAsset(hash: "rate1")
        one.rating = 1
        var three = TestFixtures.makeAsset(hash: "rate3")
        three.rating = 3
        var five = TestFixtures.makeAsset(hash: "rate5")
        five.rating = 5
        try catalog.insertAsset(one)
        try catalog.insertAsset(three)
        try catalog.insertAsset(five)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.count, 3, "minRating=0 shows everything")

        await vm.setMinRating(3)
        XCTAssertEqual(vm.minRating, 3)
        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertTrue(vm.rows.allSatisfy { $0.asset.rating >= 3 })

        // Dropping back to 0 brings the 1-star row back.
        await vm.setMinRating(0)
        XCTAssertEqual(vm.rows.count, 3)
    }

    /// The nav helpers already walk `rows`, so filtering naturally makes
    /// `selectNext` skip filtered rows. This test confirms that
    /// end-to-end: after a filter is set and the 1-star row is hidden,
    /// selecting the 5-star row and pressing next lands on the 3-star.
    @MainActor
    func testSelectNextSkipsFilteredRows() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var one = TestFixtures.makeAsset(
            hash: "nav1",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        one.rating = 1
        var three = TestFixtures.makeAsset(
            hash: "nav3",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        three.rating = 3
        var five = TestFixtures.makeAsset(
            hash: "nav5",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        five.rating = 5
        try catalog.insertAsset(one)
        try catalog.insertAsset(three)
        try catalog.insertAsset(five)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        await vm.setMinRating(3)
        // Rows are sorted newest-first: [five, three] only.
        XCTAssertEqual(vm.rows.map(\.id), [five.id, three.id])

        vm.select(five.id)
        vm.selectNext()
        XCTAssertEqual(
            vm.selectedAssetId,
            three.id,
            "selectNext must jump straight to the 3-star row, skipping the hidden 1-star"
        )
        vm.selectNext()
        XCTAssertEqual(
            vm.selectedAssetId,
            three.id,
            "selectNext at the last visible row is a no-op"
        )
    }

    @MainActor
    func testSetRatingPersistsAndReloads() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "ratee")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.first?.asset.rating, 0)

        await vm.setRating(for: asset.id, to: 4)
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.asset.rating, 4)

        // Fetch through the catalog too — the in-memory row could be
        // out of sync with the database if `reload` was skipped.
        let fetched = try catalog.fetchAsset(byHash: "ratee")
        XCTAssertEqual(fetched?.rating, 4)
    }

    @MainActor
    func testSetRatingToZeroClearsTheStar() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var asset = TestFixtures.makeAsset(hash: "clear")
        asset.rating = 5
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.first?.asset.rating, 5)

        await vm.setRating(for: asset.id, to: 0)
        XCTAssertEqual(vm.rows.first?.asset.rating, 0)
    }

    // MARK: - Import session scope

    @MainActor
    func testSetScopeFiltersRows() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let s1 = ImportSession(sourceKind: "folder")
        let s2 = ImportSession(sourceKind: "folder")
        try catalog.insertImportSession(s1)
        try catalog.insertImportSession(s2)

        var a1 = TestFixtures.makeAsset(hash: "scope1")
        a1.importSessionId = s1.id
        var a2 = TestFixtures.makeAsset(hash: "scope2")
        a2.importSessionId = s1.id
        var a3 = TestFixtures.makeAsset(hash: "scope3")
        a3.importSessionId = s2.id
        try catalog.insertAsset(a1)
        try catalog.insertAsset(a2)
        try catalog.insertAsset(a3)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.count, 3)

        await vm.setScope(s1.id)
        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertTrue(vm.rows.allSatisfy { $0.asset.importSessionId == s1.id })
    }

    @MainActor
    func testSetScopeNilShowsAll() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let s1 = ImportSession(sourceKind: "folder")
        try catalog.insertImportSession(s1)

        var a1 = TestFixtures.makeAsset(hash: "allscope1")
        a1.importSessionId = s1.id
        var a2 = TestFixtures.makeAsset(hash: "allscope2")
        // a2 has no session (pre-existing asset)
        try catalog.insertAsset(a1)
        try catalog.insertAsset(a2)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        await vm.setScope(s1.id)
        XCTAssertEqual(vm.rows.count, 1)

        await vm.setScope(nil)
        XCTAssertEqual(vm.rows.count, 2)
    }

    @MainActor
    func testArrowNavigationRespectsScope() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let s1 = ImportSession(sourceKind: "folder")
        try catalog.insertImportSession(s1)

        var a1 = TestFixtures.makeAsset(
            hash: "nav-s1",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        a1.importSessionId = s1.id
        var a2 = TestFixtures.makeAsset(
            hash: "nav-s2",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        a2.importSessionId = s1.id
        var a3 = TestFixtures.makeAsset(
            hash: "nav-other",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        // a3 in a different session — should not appear when scoped to s1
        try catalog.insertAsset(a1)
        try catalog.insertAsset(a2)
        try catalog.insertAsset(a3)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.setScope(s1.id)
        // Rows: [a1, a2] (newest first)
        XCTAssertEqual(vm.rows.count, 2)

        vm.select(a1.id)
        vm.selectNext()
        XCTAssertEqual(vm.selectedAssetId, a2.id)
        vm.selectNext()
        // At end of scoped rows — no-op
        XCTAssertEqual(vm.selectedAssetId, a2.id)
    }

    @MainActor
    func testRecentSessionsPopulatedOnReload() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let s1 = ImportSession(sourceKind: "folder", sourceDevice: "Camera A")
        let s2 = ImportSession(sourceKind: "folder", sourceDevice: "Camera B")
        try catalog.insertImportSession(s1)
        try catalog.insertImportSession(s2)

        var a1 = TestFixtures.makeAsset(hash: "rs1")
        a1.importSessionId = s1.id
        var a2 = TestFixtures.makeAsset(hash: "rs2")
        a2.importSessionId = s2.id
        try catalog.insertAsset(a1)
        try catalog.insertAsset(a2)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        XCTAssertEqual(vm.recentSessions.count, 2)
    }

    // MARK: - Rotation

    /// Cycles the rotation value four times and asserts it lands on
    /// `90 → 180 → 270 → 0`. Uses a real on-disk JPEG so
    /// `PreviewStore.generate` has something to decode from — otherwise
    /// the `rotate` path would short-circuit on the nil localPath.
    @MainActor
    func testRotateCyclesThroughAllFourOrientations() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let sourceURL = try writeSolidJPEG(named: "rotate-source.jpg")
        var asset = TestFixtures.makeAsset(hash: "rotation")
        asset.localPath = sourceURL.path
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        let expectedRotations = [90, 180, 270, 0]
        for expected in expectedRotations {
            await vm.rotate(assetId: asset.id)
            let fetched = try catalog.fetchAsset(byHash: "rotation")
            XCTAssertEqual(
                fetched?.rotation,
                expected,
                "rotate() must persist the new orientation to the catalog"
            )
        }
    }

    /// On rotate, the view model must bump `rowVersion` and the cached
    /// thumbnail on disk must be regenerated (not just deleted). Uses a
    /// real `PreviewStore` so the generate round-trip runs.
    @MainActor
    func testRotateBumpsRowVersionAndRegeneratesPreview() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let sourceURL = try writeSolidJPEG(named: "rotate-regen.jpg")
        var asset = TestFixtures.makeAsset(hash: "regen")
        asset.localPath = sourceURL.path
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        // Prime the cache so we know the thumb exists before rotate.
        _ = try await store.generate(for: asset, sourceURL: sourceURL)
        let thumbURL = try XCTUnwrap(store.thumbnailURL(for: asset))
        let firstMtime = try FileManager.default
            .attributesOfItem(atPath: thumbURL.path)[.modificationDate] as? Date
        XCTAssertNotNil(firstMtime)

        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        let startingVersion = vm.rowVersion

        // Sleep-less mtime bump — write a marker byte into the file so
        // the new mtime is guaranteed to differ from the old one even
        // on filesystems with second-resolution timestamps.
        try? FileManager.default.removeItem(at: thumbURL)

        await vm.rotate(assetId: asset.id)

        XCTAssertGreaterThan(
            vm.rowVersion,
            startingVersion,
            "rotate() must bump the row version"
        )
        // A new thumbnail must have been written at the cached location.
        let postThumbURL = try XCTUnwrap(store.thumbnailURL(for: asset))
        XCTAssertEqual(postThumbURL.path, thumbURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: postThumbURL.path))

        // The catalog row must reflect the new rotation.
        let fetched = try catalog.fetchAsset(byHash: "regen")
        XCTAssertEqual(fetched?.rotation, 90)
    }

    @MainActor
    func testRotateWithoutLocalPathStillUpdatesCatalog() async throws {
        // Drive-only asset: no localPath, so regenerate has to be a
        // no-op, but the catalog value still needs to change so a later
        // sync can pick up the new orientation.
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "driveonly")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        await vm.rotate(assetId: asset.id)

        let fetched = try catalog.fetchAsset(byHash: "driveonly")
        XCTAssertEqual(fetched?.rotation, 90)
    }

    /// CCW rotation must cycle 270 → 180 → 90 → 0. This is the mirror
    /// image of the CW test above.
    @MainActor
    func testRotateCCWCyclesThroughAllFourOrientations() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "ccwrot")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        let expectedRotations = [270, 180, 90, 0]
        for expected in expectedRotations {
            await vm.rotate(assetId: asset.id, clockwise: false)
            let fetched = try catalog.fetchAsset(byHash: "ccwrot")
            XCTAssertEqual(
                fetched?.rotation,
                expected,
                "rotate(clockwise: false) must produce CCW rotation"
            )
        }
    }

    /// Setting a non-zero rating must publish a `ratingToast` so the UI
    /// can show visual feedback. Setting to 0 must clear it.
    @MainActor
    func testSetRatingPublishesToast() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "toastee")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        XCTAssertNil(vm.ratingToast)

        await vm.setRating(for: asset.id, to: 3)
        XCTAssertEqual(vm.ratingToast?.rating, 3)
        XCTAssertEqual(vm.ratingToast?.assetId, asset.id)

        await vm.setRating(for: asset.id, to: 0)
        XCTAssertNil(vm.ratingToast, "Rating 0 must clear the toast")
    }

    // MARK: - Zoom command trigger

    @MainActor
    func testPendingZoomCommandStartsNil() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        XCTAssertNil(vm.pendingZoomCommand)
    }

    @MainActor
    func testPendingZoomCommandCanBeSetAndCleared() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        vm.pendingZoomCommand = .toggleFitTo100
        XCTAssertEqual(vm.pendingZoomCommand, .toggleFitTo100)

        vm.pendingZoomCommand = nil
        XCTAssertNil(vm.pendingZoomCommand)

        vm.pendingZoomCommand = .resetToFit
        XCTAssertEqual(vm.pendingZoomCommand, .resetToFit)

        vm.pendingZoomCommand = nil
        XCTAssertNil(vm.pendingZoomCommand)
    }

    // MARK: - Helpers

    /// Produce a minimal 64×48 solid-red JPEG on disk and return its
    /// URL. This is the local-path source used by rotate tests so
    /// `PreviewStore.generate` has a real file to decode.
    private func writeSolidJPEG(named name: String) throws -> URL {
        let url = tempCacheDir.appendingPathComponent(name)
        try TestFixtures.writeSolidJPEG(
            width: 64,
            height: 48,
            color: (r: 220, g: 30, b: 30),
            to: url
        )
        return url
    }
}
