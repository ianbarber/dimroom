import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

/// Layer A tests for the soft-delete / restore / permanent-delete path
/// on `LibraryViewModel`, plus the undo toast lifecycle and the
/// Recently Deleted scope.
final class DeleteUndoTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-delete-\(UUID().uuidString)")
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

    // MARK: - deleteSelected / deleteAssets

    @MainActor
    func testDeleteSelectedRemovesFromRowsAndPostsToast() async throws {
        let (vm, ids) = try await makeViewModel(count: 4)
        vm.select(ids[0])
        vm.toggleSelect(ids[2])

        await vm.deleteSelected()

        let remaining = vm.rows.map(\.id)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains(ids[0]))
        XCTAssertFalse(remaining.contains(ids[2]))
        XCTAssertTrue(vm.selectedAssetIds.isEmpty, "selection clears after delete")

        let toast = try XCTUnwrap(vm.undoToast)
        XCTAssertEqual(Set(toast.deletedIds), [ids[0], ids[2]])
    }

    @MainActor
    func testDeleteSelectedNoopWhenSelectionEmpty() async throws {
        let (vm, _) = try await makeViewModel(count: 2)
        XCTAssertTrue(vm.selectedAssetIds.isEmpty)

        await vm.deleteSelected()

        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertNil(vm.undoToast, "nothing selected → no toast")
    }

    @MainActor
    func testDeleteAssetsDirectlyBypassesSelection() async throws {
        let (vm, ids) = try await makeViewModel(count: 3)
        await vm.deleteAssets(ids: [ids[1]])

        XCTAssertEqual(vm.rows.count, 2)
        let toast = try XCTUnwrap(vm.undoToast)
        XCTAssertEqual(toast.deletedIds, [ids[1]])
    }

    // MARK: - undo

    @MainActor
    func testUndoLastDeleteRestoresRows() async throws {
        let (vm, ids) = try await makeViewModel(count: 3)
        vm.select(ids[0])
        vm.toggleSelect(ids[1])

        await vm.deleteSelected()
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertNotNil(vm.undoToast)

        await vm.undoLastDelete()

        XCTAssertEqual(vm.rows.count, 3)
        XCTAssertNil(vm.undoToast, "undoing dismisses the toast")
    }

    @MainActor
    func testUndoLastDeleteAfterToastClearedIsNoop() async throws {
        let (vm, ids) = try await makeViewModel(count: 2)
        vm.select(ids[0])
        await vm.deleteSelected()
        XCTAssertNotNil(vm.undoToast)

        vm.undoToast = nil
        await vm.undoLastDelete()

        XCTAssertEqual(vm.rows.count, 1, "no toast → nothing to undo")
    }

    // MARK: - Recently Deleted scope

    @MainActor
    func testRecentlyDeletedScopeShowsOnlyTrash() async throws {
        let (vm, ids) = try await makeViewModel(count: 3)
        vm.select(ids[0])
        vm.toggleSelect(ids[1])
        await vm.deleteSelected()
        XCTAssertEqual(vm.rows.count, 1)

        await vm.setScope(.recentlyDeleted)
        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertEqual(Set(vm.rows.map(\.id)), [ids[0], ids[1]])
    }

    @MainActor
    func testRestoreFromRecentlyDeletedPutsItBack() async throws {
        let (vm, ids) = try await makeViewModel(count: 3)
        await vm.deleteAssets(ids: [ids[0], ids[1]])
        await vm.setScope(.recentlyDeleted)
        XCTAssertEqual(vm.rows.count, 2)

        await vm.restoreAssets(ids: [ids[0]])

        // After restore the trash scope has just one row left.
        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows.first?.id, ids[1])

        // Back in "all" scope, the restored asset is visible again.
        await vm.setScope(.all)
        XCTAssertEqual(vm.rows.count, 2)
        XCTAssertTrue(vm.rows.contains { $0.id == ids[0] })
    }

    @MainActor
    func testPermanentlyDeleteRemovesRowFromCatalog() async throws {
        let (vm, ids) = try await makeViewModel(count: 3)
        await vm.deleteAssets(ids: [ids[0]])
        await vm.setScope(.recentlyDeleted)

        await vm.permanentlyDeleteAssets(ids: [ids[0]])

        XCTAssertEqual(vm.rows.count, 0, "trash is empty after permanent delete")

        // Row is gone from the catalog entirely — even the include-deleted
        // filter doesn't see it.
        let all = try await loadAllWithDeleted(vm: vm)
        XCTAssertFalse(all.contains { $0.id == ids[0] })
    }

    @MainActor
    func testReloadPrunesSelectionForDeletedRows() async throws {
        let (vm, ids) = try await makeViewModel(count: 3)
        vm.selectAllVisible()
        XCTAssertEqual(vm.selectedAssetIds.count, 3)

        await vm.deleteAssets(ids: [ids[0], ids[1]])
        // deleteAssets clears selection, but cover the pure reload path
        // too — select the survivor, then soft-delete it through the
        // catalog directly so we can confirm reload prunes it.
        vm.select(ids[2])
        try catalog(for: vm).deleteAsset(id: ids[2])
        await vm.reloadAndWait()

        XCTAssertTrue(vm.selectedAssetIds.isEmpty, "reload drops vanished ids")
        XCTAssertNil(vm.primarySelectedAssetId)
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(count: Int) async throws -> (LibraryViewModel, [UUID]) {
        let catalog = try CatalogDatabase.inMemory()
        var ids: [UUID] = []
        for i in 0..<count {
            let asset = TestFixtures.makeAsset(
                hash: "del-\(i)",
                captureDate: Date(timeIntervalSince1970: 2_000_000 - Double(i))
            )
            ids.append(asset.id)
            try catalog.insertAsset(asset)
        }
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        // `ids` ordered by captureDate descending — matches the view
        // model's sort so rows[i].id == ids[i].
        XCTAssertEqual(vm.rows.map(\.id), ids)
        return (vm, ids)
    }

    @MainActor
    private func catalog(for vm: LibraryViewModel) -> CatalogDatabase {
        // Mirror-based accessor avoids forcing the production code to
        // leak the catalog just for tests. Views stay sealed.
        let mirror = Mirror(reflecting: vm)
        for child in mirror.children {
            if let cat = child.value as? CatalogDatabase {
                return cat
            }
        }
        fatalError("catalog not found via mirror — did LibraryViewModel rename it?")
    }

    @MainActor
    private func loadAllWithDeleted(vm: LibraryViewModel) async throws -> [Asset] {
        try catalog(for: vm).fetchAssets(filter: AssetFilter(includeDeleted: true))
    }
}
