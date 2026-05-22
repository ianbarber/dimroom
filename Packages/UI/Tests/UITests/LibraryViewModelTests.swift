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
    func testFocusMovesPrimaryWithoutAddingToSelection() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let id = UUID()
        vm.focus(id)

        XCTAssertEqual(vm.primarySelectedAssetId, id)
        XCTAssertTrue(vm.selectedAssetIds.isEmpty)
    }

    @MainActor
    func testFocusPreservesExistingMultiSelection() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let a = TestFixtures.makeAsset(hash: "focus-a")
        let b = TestFixtures.makeAsset(hash: "focus-b")
        let c = TestFixtures.makeAsset(hash: "focus-c")
        try catalog.insertAsset(a)
        try catalog.insertAsset(b)
        try catalog.insertAsset(c)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

        vm.select(a.id)
        vm.toggleSelect(b.id)
        vm.toggleSelect(c.id)
        let before = vm.selectedAssetIds
        XCTAssertEqual(before, [a.id, b.id, c.id])

        vm.focus(a.id)

        XCTAssertEqual(vm.primarySelectedAssetId, a.id)
        XCTAssertEqual(vm.selectedAssetIds, before)
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

    /// `recentImportsLimit` plumbs the user-configurable cap from Settings
    /// → General into `catalog.fetchImportSessions(limit:)`. With limit=1
    /// and two seeded sessions, only the most recent surfaces.
    @MainActor
    func testRecentImportsLimitCapsScopePicker() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let s1 = ImportSession(sourceKind: "folder", sourceDevice: "Camera A")
        let s2 = ImportSession(sourceKind: "folder", sourceDevice: "Camera B")
        try catalog.insertImportSession(s1)
        try catalog.insertImportSession(s2)
        var a1 = TestFixtures.makeAsset(hash: "rl1")
        a1.importSessionId = s1.id
        var a2 = TestFixtures.makeAsset(hash: "rl2")
        a2.importSessionId = s2.id
        try catalog.insertAsset(a1)
        try catalog.insertAsset(a2)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.recentImportsLimit = 1
        await vm.reloadAndWait()

        XCTAssertEqual(vm.recentSessions.count, 1)
    }

    /// `columnCount` is now instance-level. Up/Down arrow navigation
    /// reads the live value, so a user with `columnCount = 3` should
    /// skip 3 rows per Down/Up, not the previous hardcoded 4.
    @MainActor
    func testColumnCountInstanceValueDrivesSelectDown() async throws {
        let catalog = try CatalogDatabase.inMemory()
        // Seed 9 assets with monotonically increasing capture dates so
        // the grid order is predictable.
        var assets: [Asset] = []
        for i in 0..<9 {
            let asset = TestFixtures.makeAsset(
                hash: "row-\(i)",
                captureDate: Date(timeIntervalSince1970: Double(1_000_000 - i))
            )
            assets.append(asset)
            try catalog.insertAsset(asset)
        }
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        vm.columnCount = 3
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.count, 9)

        // Select the first row, then move down — with columnCount=3 the
        // skip-by-3 should land on the asset at index 3.
        vm.select(vm.rows[0].id)
        vm.selectDown()
        XCTAssertEqual(vm.selectedAssetId, vm.rows[3].id)
    }

    // MARK: - Delete is a no-op in Recently Deleted

    /// Backspace / Edit → Delete Selected in the `.recentlyDeleted`
    /// scope must not re-soft-delete trash rows (which would extend the
    /// 30-day retention window) and must not push a misleading undo
    /// toast. Regression for #181.
    @MainActor
    func testDeleteSelectedIsNoOpInRecentlyDeletedScope() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "trash-noop")
        try catalog.insertAsset(asset)
        // Soft-delete directly through the catalog so the asset lands in
        // the trash without going through the VM's delete path (which
        // would consume the assertion we want to make).
        try catalog.deleteAsset(id: asset.id)
        let original = try XCTUnwrap(catalog.fetchAsset(byHash: "trash-noop"))
        let originalDeletedAt = try XCTUnwrap(original.deletedAt)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.setScope(.recentlyDeleted)
        XCTAssertEqual(vm.rows.map(\.id), [asset.id])

        vm.select(asset.id)
        await vm.deleteSelected()

        XCTAssertNil(vm.undoToast, "Delete in trash must not show an undo toast")
        XCTAssertEqual(vm.rows.count, 1, "Trash row must still be present")
        let after = try XCTUnwrap(catalog.fetchAsset(byHash: "trash-noop"))
        XCTAssertEqual(
            after.deletedAt,
            originalDeletedAt,
            "deletedAt must not be advanced by a no-op delete in trash"
        )
    }

    /// Same invariant via the harness entry point: `deleteAssets(ids:)`
    /// is what `HarnessController` reaches for the `delete-assets`
    /// command, so guarding only `deleteSelected` would leave the
    /// scriptable path uncovered.
    @MainActor
    func testDeleteAssetsIsNoOpInRecentlyDeletedScope() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "trash-noop-harness")
        try catalog.insertAsset(asset)
        try catalog.deleteAsset(id: asset.id)
        let original = try XCTUnwrap(catalog.fetchAsset(byHash: "trash-noop-harness"))
        let originalDeletedAt = try XCTUnwrap(original.deletedAt)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.setScope(.recentlyDeleted)

        await vm.deleteAssets(ids: [asset.id])

        XCTAssertNil(vm.undoToast)
        XCTAssertEqual(vm.rows.count, 1)
        let after = try XCTUnwrap(catalog.fetchAsset(byHash: "trash-noop-harness"))
        XCTAssertEqual(after.deletedAt, originalDeletedAt)
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

    // MARK: - isZoomed

    @MainActor
    func testIsZoomedDefaultsToFalse() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        XCTAssertFalse(vm.isZoomed)
    }

    @MainActor
    func testIsZoomedCanBeSet() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        vm.isZoomed = true
        XCTAssertTrue(vm.isZoomed)

        vm.isZoomed = false
        XCTAssertFalse(vm.isZoomed)
    }

    // MARK: - Undo / redo integration

    @MainActor
    func testUndoAfterSetRatingRestoresPreviousValue() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "undo-rating")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        let stack = UndoStack(catalog: catalog, libraryViewModel: vm)
        vm.undoStack = stack
        await vm.reloadAndWait()

        await vm.setRating(for: asset.id, to: 3)
        XCTAssertEqual(vm.rows.first?.asset.rating, 3)
        XCTAssertTrue(stack.canUndo)

        await stack.undo()
        XCTAssertEqual(vm.rows.first?.asset.rating, 0)
        XCTAssertFalse(stack.canUndo)
        XCTAssertTrue(stack.canRedo)
    }

    @MainActor
    func testRedoAfterUndoReappliesRatingChange() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "redo-rating")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        let stack = UndoStack(catalog: catalog, libraryViewModel: vm)
        vm.undoStack = stack
        await vm.reloadAndWait()

        await vm.setRating(for: asset.id, to: 4)
        await stack.undo()
        XCTAssertEqual(vm.rows.first?.asset.rating, 0)

        await stack.redo()
        XCTAssertEqual(vm.rows.first?.asset.rating, 4)
    }

    /// Two rating changes in a row should push two frames. Two undos walk
    /// back through both; a third undo is a no-op.
    @MainActor
    func testTwoRatingChangesWalkBackThroughBoth() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "undo-two")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        let stack = UndoStack(catalog: catalog, libraryViewModel: vm)
        vm.undoStack = stack
        await vm.reloadAndWait()

        await vm.setRating(for: asset.id, to: 2)
        await vm.setRating(for: asset.id, to: 4)
        XCTAssertEqual(vm.rows.first?.asset.rating, 4)

        await stack.undo()
        XCTAssertEqual(vm.rows.first?.asset.rating, 2)

        await stack.undo()
        XCTAssertEqual(vm.rows.first?.asset.rating, 0)

        // Third undo: no-op.
        await stack.undo()
        XCTAssertEqual(vm.rows.first?.asset.rating, 0)
    }

    @MainActor
    func testUndoAfterRotateRestoresRotation() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "undo-rotate")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        let stack = UndoStack(catalog: catalog, libraryViewModel: vm)
        vm.undoStack = stack
        await vm.reloadAndWait()

        await vm.rotate(assetId: asset.id)
        let afterRotate = try catalog.fetchAsset(byHash: "undo-rotate")
        XCTAssertEqual(afterRotate?.rotation, 90)

        await stack.undo()
        let afterUndo = try catalog.fetchAsset(byHash: "undo-rotate")
        XCTAssertEqual(afterUndo?.rotation, 0)
    }

    /// Redo after a rating undo must re-apply the clamp + toast path, not
    /// the raw catalog write. This exercises the view-model entrypoint
    /// that `UndoStack.apply` reaches for rating replay.
    @MainActor
    func testRedoRatingRepublishesToast() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "redo-toast")
        try catalog.insertAsset(asset)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        let stack = UndoStack(catalog: catalog, libraryViewModel: vm)
        vm.undoStack = stack
        await vm.reloadAndWait()

        await vm.setRating(for: asset.id, to: 5)
        await stack.undo()
        await stack.redo()
        XCTAssertEqual(vm.ratingToast?.rating, 5)
    }

    // MARK: - Original fetch progress

    /// Drive the stub through three increasing ticks and snapshot the
    /// view-model dictionary at each one. The stub waits on `onTick`
    /// before issuing the next progress value, so each snapshot reflects
    /// the *exact* value just published.
    @MainActor
    func testFetchOriginalIfNeededPublishesProgress() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let assetId = UUID()
        let snapshots = ProgressSnapshots()
        let fetcher = StubProgressFetcher(
            resultURL: resultURL,
            ticks: [0.25, 0.6, 1.0],
            onTick: { @Sendable in
                await MainActor.run {
                    snapshots.append(vm.downloadProgressByAssetId[assetId])
                }
            }
        )
        vm.originalFetcher = fetcher

        let returned = await vm.fetchOriginalIfNeeded(assetId: assetId)
        XCTAssertEqual(returned, resultURL)
        XCTAssertEqual(snapshots.values, [0.25, 0.6, 1.0])
    }

    /// Feed `[0.5, 0.3]` and confirm the second (lower) tick does not
    /// move the published value backwards.
    @MainActor
    func testFetchOriginalIfNeededClampsMonotonic() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let assetId = UUID()
        let snapshots = ProgressSnapshots()
        let fetcher = StubProgressFetcher(
            resultURL: resultURL,
            ticks: [0.5, 0.3],
            onTick: { @Sendable in
                await MainActor.run {
                    snapshots.append(vm.downloadProgressByAssetId[assetId])
                }
            }
        )
        vm.originalFetcher = fetcher

        _ = await vm.fetchOriginalIfNeeded(assetId: assetId)
        XCTAssertEqual(snapshots.values, [0.5, 0.5],
                       "second (lower) tick must not move the value backwards")
    }

    @MainActor
    func testFetchOriginalIfNeededClearsProgressOnSuccess() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let fetcher = StubProgressFetcher(
            resultURL: resultURL,
            ticks: [0.9]
        )
        vm.originalFetcher = fetcher

        let assetId = UUID()
        _ = await vm.fetchOriginalIfNeeded(assetId: assetId)
        XCTAssertNil(
            vm.downloadProgressByAssetId[assetId],
            "progress entry must be cleared once the fetch resolves"
        )
        XCTAssertFalse(vm.downloadingAssetIds.contains(assetId))
    }

    @MainActor
    func testFetchOriginalIfNeededClearsProgressOnFailure() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let fetcher = StubProgressFetcher(
            resultURL: nil,
            ticks: [0.4]
        )
        vm.originalFetcher = fetcher

        let assetId = UUID()
        let url = await vm.fetchOriginalIfNeeded(assetId: assetId)
        XCTAssertNil(url)
        XCTAssertNil(
            vm.downloadProgressByAssetId[assetId],
            "failed fetch must still clear the progress entry"
        )
    }

    /// A progress tick whose `Task { @MainActor }` runs *after*
    /// `fetchOriginalIfNeeded` has already cleared state must be a no-op.
    /// Regression guard for the race between the cleanup `defer` and
    /// fire-and-forget progress writes scheduled from the fetcher's
    /// delegate thread.
    @MainActor
    func testFetchOriginalIfNeededIgnoresProgressTickAfterReturn() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let fetcher = DeferredProgressFetcher(resultURL: resultURL)
        vm.originalFetcher = fetcher

        let assetId = UUID()
        let returned = await vm.fetchOriginalIfNeeded(assetId: assetId)
        XCTAssertEqual(returned, resultURL)

        // Simulate the late delegate tick: invoke the captured closure
        // *after* fetchOriginalIfNeeded has resolved and the defer has
        // run. Drain any Task the closure schedules onto the main actor.
        let captured = await fetcher.capturedProgress
        captured?(1.0)
        await MainActor.run { }

        XCTAssertNil(
            vm.downloadProgressByAssetId[assetId],
            "late progress tick must not resurrect a cleared entry"
        )
        XCTAssertFalse(vm.downloadingAssetIds.contains(assetId))
    }

    /// Back-to-back re-fetch of the same asset must not let a late
    /// progress tick from the *previous* fetch pollute the *next* fetch's
    /// slot. The bug shape: fetch N's progress `Task` is queued; N
    /// returns and its defer clears state; the UI immediately re-fetches
    /// the same asset (N+1) which re-inserts the asset id into the
    /// in-flight set; the queued Task from N runs and writes its (stale)
    /// fraction into N+1's slot. The fetch-id gate added in this commit
    /// makes the queued Task notice it no longer owns the slot and bail.
    @MainActor
    func testFetchOriginalIfNeededDoesNotPolluteRefetchWithStaleTick() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let fetcher = ControlledProgressFetcher(resultURL: resultURL)
        vm.originalFetcher = fetcher
        let assetId = UUID()

        // Fetch N: kick off, wait for it to reach the fetcher, then
        // resolve so its defer fully runs.
        let firstTask = Task { @MainActor in
            await vm.fetchOriginalIfNeeded(assetId: assetId)
        }
        await fetcher.waitForStart()
        await fetcher.resolveNext()
        _ = await firstTask.value

        XCTAssertNil(
            vm.downloadProgressByAssetId[assetId],
            "fetch N's defer must clear its own progress entry"
        )
        XCTAssertFalse(vm.downloadingAssetIds.contains(assetId))

        // Fetch N+1: same asset id, kick off and wait until it has
        // reached the fetcher (and therefore inserted its own state).
        // Do NOT resolve yet.
        let secondTask = Task { @MainActor in
            await vm.fetchOriginalIfNeeded(assetId: assetId)
        }
        await fetcher.waitForStart()
        XCTAssertTrue(
            vm.downloadingAssetIds.contains(assetId),
            "N+1 must mark the asset as in-flight before the stale tick fires"
        )

        // Fire fetch N's captured progress closure with a high value.
        // Without the fetch-id gate this would land at 1.0 in N+1's slot.
        let staleClosure = await fetcher.capturedProgress(at: 0)
        staleClosure?(1.0)
        // Drain pending @MainActor tasks so the closure's Task runs.
        await MainActor.run { }

        XCTAssertNil(
            vm.downloadProgressByAssetId[assetId],
            "stale tick from fetch N must not populate N+1's progress slot"
        )

        // Tear down: resolve N+1 so its task can exit.
        await fetcher.resolveNext()
        _ = await secondTask.value
        XCTAssertFalse(vm.downloadingAssetIds.contains(assetId))
    }

    /// Regression for the defer-clobber half of the same race covered by
    /// `testFetchOriginalIfNeededDoesNotPolluteRefetchWithStaleTick`. Here
    /// fetch N+1 starts on the same asset id *before* fetch N's `defer`
    /// runs (concurrent in-flight). Without the
    /// `currentFetchIdByAssetId[assetId] == fetchId` guard inside the
    /// defer, N's cleanup would unconditionally remove `assetId` from
    /// `downloadingAssetIds` and wipe `downloadProgressByAssetId[assetId]`,
    /// even though those slots now belong to N+1.
    @MainActor
    func testFetchOriginalIfNeededConcurrentInFlightDoesNotClobberSlotOnFirstDefer() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let fetcher = ControlledProgressFetcher(resultURL: resultURL)
        vm.originalFetcher = fetcher
        let assetId = UUID()

        // Fetch N: kick off, wait until it has reached the fetcher.
        // Do NOT resolve yet.
        let firstTask = Task { @MainActor in
            await vm.fetchOriginalIfNeeded(assetId: assetId)
        }
        await fetcher.waitForStart()

        // Fetch N+1: same asset id, kick off and wait until it has also
        // reached the fetcher. This overwrites currentFetchIdByAssetId
        // with N+1's id; N's defer must notice the mismatch when it runs.
        let secondTask = Task { @MainActor in
            await vm.fetchOriginalIfNeeded(assetId: assetId)
        }
        await fetcher.waitForStart()

        // Publish a concrete progress value through N+1's closure so the
        // survival assertion below discriminates: without this, the test
        // would pass whether or not the defer-clobber regression returns.
        let nextClosure = await fetcher.capturedProgress(at: 1)
        nextClosure?(0.4)
        await MainActor.run { }

        // Resolve N (FIFO). Its defer runs and must hit the id mismatch
        // and skip the clear.
        await fetcher.resolveNext()
        _ = await firstTask.value

        XCTAssertTrue(
            vm.downloadingAssetIds.contains(assetId),
            "fetch N's defer must leave the in-flight slot in place for N+1"
        )
        XCTAssertEqual(
            vm.downloadProgressByAssetId[assetId],
            0.4,
            "fetch N's defer must leave N+1's progress entry intact"
        )

        // Tear down: resolve N+1 so its task can exit; state should
        // finally be clean.
        await fetcher.resolveNext()
        _ = await secondTask.value
        XCTAssertFalse(vm.downloadingAssetIds.contains(assetId))
        XCTAssertNil(vm.downloadProgressByAssetId[assetId])
    }

    /// Sanity guard against over-gating: a tick fired *during* a fetch
    /// (same fetch-id) still lands in `downloadProgressByAssetId`. This
    /// is the happy-path that `testFetchOriginalIfNeededPublishesProgress`
    /// covers implicitly; here we exercise it through the controlled
    /// fetcher so the id-match path is intentional, not incidental.
    @MainActor
    func testFetchOriginalIfNeededSameFetchTickLands() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let resultURL = tempCacheDir.appendingPathComponent("orig.jpg")
        let fetcher = ControlledProgressFetcher(resultURL: resultURL)
        vm.originalFetcher = fetcher
        let assetId = UUID()

        let task = Task { @MainActor in
            await vm.fetchOriginalIfNeeded(assetId: assetId)
        }
        await fetcher.waitForStart()

        let progress = await fetcher.capturedProgress(at: 0)
        progress?(0.42)
        await MainActor.run { }

        XCTAssertEqual(
            vm.downloadProgressByAssetId[assetId],
            0.42,
            "tick fired during the same fetch must land in the progress slot"
        )

        await fetcher.resolveNext()
        _ = await task.value
    }

    @MainActor
    func testFetchOriginalIfNeededWithoutFetcherLeavesDictionaryEmpty() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        XCTAssertNil(vm.originalFetcher)

        let assetId = UUID()
        let url = await vm.fetchOriginalIfNeeded(assetId: assetId)
        XCTAssertNil(url)
        XCTAssertTrue(vm.downloadProgressByAssetId.isEmpty)
        XCTAssertFalse(vm.downloadingAssetIds.contains(assetId))
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

/// Minimal `OriginalFetcher` stub: walks a fixed sequence of progress
/// values and waits for each one to be observed (via `onTick`) before
/// emitting the next. Returning the URL — or `nil` for failure — happens
/// after the final tick has been observed, so the view-model `defer`
/// only runs after the test has captured every snapshot it cares about.
private actor StubProgressFetcher: OriginalFetcher {
    private let resultURL: URL?
    private let ticks: [Double]
    private let onTick: (@Sendable () async -> Void)?

    init(
        resultURL: URL?,
        ticks: [Double],
        onTick: (@Sendable () async -> Void)? = nil
    ) {
        self.resultURL = resultURL
        self.ticks = ticks
        self.onTick = onTick
    }

    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        for tick in ticks {
            progress?(tick)
            // Force pending main-actor progress writes to flush before
            // the snapshot hook runs.
            await MainActor.run { }
            if let onTick {
                await onTick()
            }
        }
        return resultURL
    }
}

/// `OriginalFetcher` stub that captures the `progress` closure without
/// invoking it and returns `resultURL` immediately, so the view-model's
/// cleanup `defer` has already run by the time the test fires a tick
/// through the captured closure.
private actor DeferredProgressFetcher: OriginalFetcher {
    private let resultURL: URL?
    var capturedProgress: (@Sendable (Double) -> Void)?

    init(resultURL: URL?) {
        self.resultURL = resultURL
    }

    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        capturedProgress = progress
        return resultURL
    }
}

/// Tiny @unchecked-Sendable bag for capturing observed progress values
/// from inside @Sendable closures. Reads/writes are confined to the
/// main actor by callers, so the lack of internal locking is fine.
private final class ProgressSnapshots: @unchecked Sendable {
    private(set) var values: [Double] = []
    func append(_ value: Double?) {
        if let value { values.append(value) }
    }
}

/// `OriginalFetcher` stub that gives the test full control over each
/// fetch's lifecycle: it captures every `progress` closure passed in,
/// signals on start, and waits on a per-call continuation before
/// returning. The test calls `waitForStart()` to synchronize on a fetch
/// having reached the fetcher, `resolveNext()` (FIFO) to let the oldest
/// in-flight fetch return, and `capturedProgress(at:)` to fire stale or
/// in-band ticks against a specific call's closure.
private actor ControlledProgressFetcher: OriginalFetcher {
    private let resultURL: URL?
    private var capturedClosures: [(@Sendable (Double) -> Void)?] = []
    private var pendingResolves: [CheckedContinuation<Void, Never>] = []
    private var pendingStarts: [CheckedContinuation<Void, Never>] = []
    private var unconsumedStarts = 0

    init(resultURL: URL?) {
        self.resultURL = resultURL
    }

    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        capturedClosures.append(progress)
        if !pendingStarts.isEmpty {
            pendingStarts.removeFirst().resume()
        } else {
            unconsumedStarts += 1
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingResolves.append(cont)
        }
        return resultURL
    }

    func waitForStart() async {
        if unconsumedStarts > 0 {
            unconsumedStarts -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingStarts.append(cont)
        }
    }

    func capturedProgress(at index: Int) -> (@Sendable (Double) -> Void)? {
        capturedClosures[index]
    }

    func resolveNext() {
        guard !pendingResolves.isEmpty else { return }
        pendingResolves.removeFirst().resume()
    }
}
