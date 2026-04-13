import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

/// Covers the prev / next navigation primitives on `LibraryViewModel`:
/// the pure `neighbor(in:from:offset:)` bounds helper and the two
/// instance methods (`selectNext`, `selectPrevious`) that delegate to it.
/// The whole point of pulling the bounds math out into a static function
/// is that these tests can run without a live view model; the instance
/// tests below exist to confirm the delegation also works end-to-end.
final class LibraryViewModelNavigationTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-ui-nav-\(UUID().uuidString)")
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

    // MARK: - Pure bounds helper

    func testNeighborAtStartReturnsNextId() {
        let ids = [uuid(1), uuid(2), uuid(3)]
        XCTAssertEqual(
            LibraryViewModel.neighbor(in: ids, from: ids[0], offset: 1),
            ids[1]
        )
    }

    func testNeighborAtEndReturnsNilForwards() {
        let ids = [uuid(1), uuid(2), uuid(3)]
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[2], offset: 1)
        )
    }

    func testNeighborAtStartReturnsNilBackwards() {
        let ids = [uuid(1), uuid(2), uuid(3)]
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[0], offset: -1)
        )
    }

    func testNeighborInMiddleMovesBothDirections() {
        let ids = [uuid(1), uuid(2), uuid(3), uuid(4), uuid(5)]
        XCTAssertEqual(
            LibraryViewModel.neighbor(in: ids, from: ids[2], offset: 1),
            ids[3]
        )
        XCTAssertEqual(
            LibraryViewModel.neighbor(in: ids, from: ids[2], offset: -1),
            ids[1]
        )
    }

    func testNeighborWithNilCurrentReturnsNil() {
        let ids = [uuid(1), uuid(2), uuid(3)]
        XCTAssertNil(LibraryViewModel.neighbor(in: ids, from: nil, offset: 1))
        XCTAssertNil(LibraryViewModel.neighbor(in: ids, from: nil, offset: -1))
    }

    func testNeighborWithUnknownCurrentReturnsNil() {
        let ids = [uuid(1), uuid(2), uuid(3)]
        let stranger = uuid(99)
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: stranger, offset: 1)
        )
    }

    func testNeighborWithSingleRowIsNoOpBothDirections() {
        let ids = [uuid(1)]
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[0], offset: 1)
        )
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[0], offset: -1)
        )
    }

    func testNeighborWithEmptyRowIdsReturnsNil() {
        let ids: [UUID] = []
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: uuid(1), offset: 1)
        )
    }

    // MARK: - Row-skip bounds helper (offset ±columnCount)

    func testNeighborSkipByColumnCountMovesDownOneRow() {
        // 8 items in a 4-column grid → 2 full rows.
        let ids = (1...8).map { uuid($0) }
        // From position 0, offset +4 → position 4 (first item of second row).
        XCTAssertEqual(
            LibraryViewModel.neighbor(in: ids, from: ids[0], offset: 4),
            ids[4]
        )
    }

    func testNeighborSkipByColumnCountMovesUpOneRow() {
        let ids = (1...8).map { uuid($0) }
        // From position 5, offset -4 → position 1.
        XCTAssertEqual(
            LibraryViewModel.neighbor(in: ids, from: ids[5], offset: -4),
            ids[1]
        )
    }

    func testNeighborSkipUpFromFirstRowReturnsNil() {
        let ids = (1...8).map { uuid($0) }
        // Position 2 is in the first row; offset -4 is out of bounds.
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[2], offset: -4)
        )
    }

    func testNeighborSkipDownFromLastRowReturnsNil() {
        let ids = (1...8).map { uuid($0) }
        // Position 5 is in the second row; offset +4 exceeds the count.
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[5], offset: 4)
        )
    }

    func testNeighborSkipDownIntoPartialLastRow() {
        // 6 items → row 0: [0,1,2,3], row 1: [4,5].
        // From position 1, offset +4 → position 5 (exists in partial row).
        let ids = (1...6).map { uuid($0) }
        XCTAssertEqual(
            LibraryViewModel.neighbor(in: ids, from: ids[1], offset: 4),
            ids[5]
        )
    }

    func testNeighborSkipDownPastPartialLastRowReturnsNil() {
        // 6 items → from position 2, offset +4 → position 6 (out of bounds).
        let ids = (1...6).map { uuid($0) }
        XCTAssertNil(
            LibraryViewModel.neighbor(in: ids, from: ids[2], offset: 4)
        )
    }

    // MARK: - Instance wiring

    @MainActor
    func testSelectNextAdvancesSelection() async throws {
        let (vm, assets) = try await makeThreeAssetViewModel()
        vm.select(assets[0].id)

        vm.selectNext()
        XCTAssertEqual(vm.selectedAssetId, assets[1].id)

        vm.selectNext()
        XCTAssertEqual(vm.selectedAssetId, assets[2].id)
    }

    @MainActor
    func testSelectNextAtEndIsNoOp() async throws {
        let (vm, assets) = try await makeThreeAssetViewModel()
        vm.select(assets[2].id)

        vm.selectNext()
        XCTAssertEqual(
            vm.selectedAssetId,
            assets[2].id,
            "selectNext at the last row must not wrap or clear"
        )
    }

    @MainActor
    func testSelectPreviousAtStartIsNoOp() async throws {
        let (vm, assets) = try await makeThreeAssetViewModel()
        vm.select(assets[0].id)

        vm.selectPrevious()
        XCTAssertEqual(
            vm.selectedAssetId,
            assets[0].id,
            "selectPrevious at the first row must not wrap or clear"
        )
    }

    @MainActor
    func testSelectNextWithNilSelectionIsNoOp() async throws {
        let (vm, _) = try await makeThreeAssetViewModel()
        XCTAssertNil(vm.selectedAssetId)

        vm.selectNext()
        XCTAssertNil(vm.selectedAssetId)

        vm.selectPrevious()
        XCTAssertNil(vm.selectedAssetId)
    }

    // MARK: - selectUp / selectDown instance wiring

    @MainActor
    func testSelectDownMovesToNextRow() async throws {
        let (vm, assets) = try await makeEightAssetViewModel()
        vm.select(assets[1].id)

        vm.selectDown()
        XCTAssertEqual(vm.selectedAssetId, assets[5].id)
    }

    @MainActor
    func testSelectUpMovesToPreviousRow() async throws {
        let (vm, assets) = try await makeEightAssetViewModel()
        vm.select(assets[5].id)

        vm.selectUp()
        XCTAssertEqual(vm.selectedAssetId, assets[1].id)
    }

    @MainActor
    func testSelectUpAtTopRowIsNoOp() async throws {
        let (vm, assets) = try await makeEightAssetViewModel()
        vm.select(assets[2].id)

        vm.selectUp()
        XCTAssertEqual(
            vm.selectedAssetId,
            assets[2].id,
            "selectUp in the first row must not wrap or clear"
        )
    }

    @MainActor
    func testSelectDownAtBottomRowIsNoOp() async throws {
        let (vm, assets) = try await makeEightAssetViewModel()
        vm.select(assets[6].id)

        vm.selectDown()
        XCTAssertEqual(
            vm.selectedAssetId,
            assets[6].id,
            "selectDown in the last row must not wrap or clear"
        )
    }

    @MainActor
    func testSelectUpDownWithNilSelectionIsNoOp() async throws {
        let (vm, _) = try await makeEightAssetViewModel()
        XCTAssertNil(vm.selectedAssetId)

        vm.selectUp()
        XCTAssertNil(vm.selectedAssetId)

        vm.selectDown()
        XCTAssertNil(vm.selectedAssetId)
    }

    // MARK: - Helpers

    /// Build a UUID with a predictable trailing byte so tests can refer
    /// to "the first id" / "the second id" without committing literals.
    private func uuid(_ suffix: UInt8) -> UUID {
        var bytes = (
            UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0),
            UInt8(0), UInt8(0), UInt8(0), UInt8(0)
        )
        bytes.15 = suffix
        return UUID(uuid: bytes)
    }

    /// Build a view model with 8 assets for testing row-based navigation.
    /// With columnCount=4, this gives exactly 2 full rows.
    @MainActor
    private func makeEightAssetViewModel() async throws -> (LibraryViewModel, [Asset]) {
        let catalog = try CatalogDatabase.inMemory()
        var assets: [Asset] = []
        for i in 0..<8 {
            let asset = TestFixtures.makeAsset(
                hash: "row\(i)",
                captureDate: Date(timeIntervalSince1970: Double(8_000_000 - i * 1_000_000))
            )
            try catalog.insertAsset(asset)
            assets.append(asset)
        }

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.map(\.id), assets.map(\.id))
        return (vm, assets)
    }

    @MainActor
    private func makeThreeAssetViewModel() async throws -> (LibraryViewModel, [Asset]) {
        let catalog = try CatalogDatabase.inMemory()
        // Newest-first sort is by captureDate; use descending timestamps
        // so assets[0] is the first row in the grid.
        let first = TestFixtures.makeAsset(
            hash: "nav1",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        let second = TestFixtures.makeAsset(
            hash: "nav2",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        let third = TestFixtures.makeAsset(
            hash: "nav3",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog.insertAsset(first)
        try catalog.insertAsset(second)
        try catalog.insertAsset(third)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.map(\.id), [first.id, second.id, third.id])
        return (vm, [first, second, third])
    }
}
