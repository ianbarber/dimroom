import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

/// Layer A tests for the multi-selection entry points on
/// `LibraryViewModel`: plain select, Cmd-click toggle, Shift-click
/// range, and Cmd+A select-all. Each test seeds the catalog, reloads,
/// and then drives the selection API directly — no SwiftUI involved.
final class MultiSelectTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-multiselect-\(UUID().uuidString)")
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

    // MARK: - select(_:)

    @MainActor
    func testSelectSingleCollapsesMultiSelection() async throws {
        let vm = try await makeViewModel(count: 3)
        let ids = vm.rows.map(\.id)

        vm.select(ids[0])
        vm.toggleSelect(ids[1])
        vm.toggleSelect(ids[2])
        XCTAssertEqual(vm.selectedAssetIds.count, 3)

        vm.select(ids[0])
        XCTAssertEqual(vm.selectedAssetIds, [ids[0]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[0])
        XCTAssertEqual(vm.selectionAnchorId, ids[0])
    }

    @MainActor
    func testSelectNilClearsEverything() async throws {
        let vm = try await makeViewModel(count: 2)
        let ids = vm.rows.map(\.id)

        vm.select(ids[0])
        vm.toggleSelect(ids[1])
        vm.select(nil)

        XCTAssertTrue(vm.selectedAssetIds.isEmpty)
        XCTAssertNil(vm.primarySelectedAssetId)
        XCTAssertNil(vm.selectionAnchorId)
    }

    // MARK: - toggleSelect(_:)

    @MainActor
    func testToggleSelectAddsAndRemoves() async throws {
        let vm = try await makeViewModel(count: 3)
        let ids = vm.rows.map(\.id)

        vm.toggleSelect(ids[0])
        XCTAssertEqual(vm.selectedAssetIds, [ids[0]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[0])

        vm.toggleSelect(ids[1])
        XCTAssertEqual(vm.selectedAssetIds, [ids[0], ids[1]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[1])

        // Toggling the current primary removes it and promotes something
        // else so the Loupe still has an asset to show.
        vm.toggleSelect(ids[1])
        XCTAssertEqual(vm.selectedAssetIds, [ids[0]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[0])
    }

    @MainActor
    func testToggleEmptiesWhenLastItemRemoved() async throws {
        let vm = try await makeViewModel(count: 2)
        let ids = vm.rows.map(\.id)

        vm.toggleSelect(ids[0])
        vm.toggleSelect(ids[0])
        XCTAssertTrue(vm.selectedAssetIds.isEmpty)
        XCTAssertNil(vm.primarySelectedAssetId)
    }

    // MARK: - extendSelect(to:)

    @MainActor
    func testExtendSelectCoversForwardRange() async throws {
        let vm = try await makeViewModel(count: 5)
        let ids = vm.rows.map(\.id)

        vm.select(ids[1])
        vm.extendSelect(to: ids[3])

        XCTAssertEqual(vm.selectedAssetIds, [ids[1], ids[2], ids[3]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[3])
        XCTAssertEqual(vm.selectionAnchorId, ids[1], "anchor must stay put for repeat shift-clicks")
    }

    @MainActor
    func testExtendSelectCoversBackwardRange() async throws {
        let vm = try await makeViewModel(count: 5)
        let ids = vm.rows.map(\.id)

        vm.select(ids[4])
        vm.extendSelect(to: ids[1])

        XCTAssertEqual(vm.selectedAssetIds, [ids[1], ids[2], ids[3], ids[4]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[1])
        XCTAssertEqual(vm.selectionAnchorId, ids[4])
    }

    @MainActor
    func testExtendSelectWithoutAnchorFallsBackToSingleSelect() async throws {
        let vm = try await makeViewModel(count: 3)
        let ids = vm.rows.map(\.id)
        XCTAssertNil(vm.selectionAnchorId)

        vm.extendSelect(to: ids[2])

        XCTAssertEqual(vm.selectedAssetIds, [ids[2]])
        XCTAssertEqual(vm.primarySelectedAssetId, ids[2])
    }

    @MainActor
    func testExtendSelectReplacesPriorSelection() async throws {
        let vm = try await makeViewModel(count: 5)
        let ids = vm.rows.map(\.id)

        vm.select(ids[0])
        vm.toggleSelect(ids[4])
        XCTAssertEqual(vm.selectedAssetIds, [ids[0], ids[4]])

        // Anchor moved with the Cmd-click onto ids[4]. Shift-click back
        // to 2 should give us the 2…4 range only — non-range ids drop.
        vm.extendSelect(to: ids[2])
        XCTAssertEqual(vm.selectedAssetIds, [ids[2], ids[3], ids[4]])
    }

    // MARK: - selectAllVisible()

    @MainActor
    func testSelectAllPicksEveryRow() async throws {
        let vm = try await makeViewModel(count: 4)
        let ids = Set(vm.rows.map(\.id))

        vm.selectAllVisible()

        XCTAssertEqual(vm.selectedAssetIds, ids)
        XCTAssertEqual(vm.primarySelectedAssetId, vm.rows.first?.id)
        XCTAssertEqual(vm.selectionAnchorId, vm.rows.first?.id)
    }

    @MainActor
    func testSelectAllNoopWhenEmpty() async throws {
        let vm = try await makeViewModel(count: 0)
        vm.selectAllVisible()
        XCTAssertTrue(vm.selectedAssetIds.isEmpty)
    }

    // MARK: - Backwards-compat aliases

    @MainActor
    func testSelectedAssetIdTracksPrimary() async throws {
        let vm = try await makeViewModel(count: 3)
        let ids = vm.rows.map(\.id)

        vm.select(ids[0])
        XCTAssertEqual(vm.selectedAssetId, ids[0])
        vm.toggleSelect(ids[2])
        XCTAssertEqual(vm.selectedAssetId, ids[2], "selectedAssetId must mirror primary")
    }

    // MARK: - Helpers

    /// Seed the catalog with `count` assets (capture dates newest-first
    /// match the grid's sort), reload, and hand back a ready view model.
    @MainActor
    private func makeViewModel(count: Int) async throws -> LibraryViewModel {
        let catalog = try CatalogDatabase.inMemory()
        for i in 0..<count {
            // Newer captureDate first so rows[0] is the newest, matching
            // how the production sort orders the grid.
            let asset = TestFixtures.makeAsset(
                hash: "ms-\(i)",
                captureDate: Date(timeIntervalSince1970: 1_000_000 - Double(i))
            )
            try catalog.insertAsset(asset)
        }
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.count, count, "view model should expose all seeded rows")
        return vm
    }
}
