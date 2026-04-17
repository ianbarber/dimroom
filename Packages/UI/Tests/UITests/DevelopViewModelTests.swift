import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

final class DevelopViewModelTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-develop-tests-\(UUID().uuidString)")
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

    // MARK: - Activate

    @MainActor
    func testActivateLoadsIdentityWhenNoEditsExist() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "no-edits")

        await vm.activate(assetId: asset.id)

        XCTAssertEqual(vm.currentAssetId, asset.id)
        XCTAssertEqual(vm.editState, EditState())
    }

    @MainActor
    func testActivateLoadsLatestEditState() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "with-edits")
        var saved = EditState()
        saved.exposure = 1.5
        saved.contrast = 25
        _ = try catalog.saveEditState(saved, for: asset.id)

        await vm.activate(assetId: asset.id)

        XCTAssertEqual(vm.editState.exposure, 1.5)
        XCTAssertEqual(vm.editState.contrast, 25)
    }

    @MainActor
    func testActivateWithNilIsNoOp() async throws {
        let (vm, _, _) = try await makeViewModelWithAsset(hash: "nil-activate")
        await vm.activate(assetId: nil)
        XCTAssertNil(vm.currentAssetId)
    }

    // MARK: - Parameter mutation

    @MainActor
    func testSetParameterUpdatesEditState() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "set-param")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 2.0)

        XCTAssertEqual(vm.editState.exposure, 2.0)
    }

    @MainActor
    func testResetParameterRestoresToIdentity() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "reset-param")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 2.0)
        XCTAssertEqual(vm.editState.exposure, 2.0)

        vm.resetParameter(\.exposure)
        XCTAssertEqual(vm.editState.exposure, 0.0)
    }

    @MainActor
    func testResetTemperatureRestoresTo6500() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "reset-temp")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.temperature, value: 3500)
        XCTAssertEqual(vm.editState.temperature, 3500)

        vm.resetParameter(\.temperature)
        XCTAssertEqual(vm.editState.temperature, 6500)
    }

    // MARK: - Auto-save debounce

    @MainActor
    func testAutoSaveAfterDebounce() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "autosave")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 1.75)

        // Debounce is 500ms; wait 800ms for it to fire.
        try await Task.sleep(nanoseconds: 800_000_000)

        let latest = try catalog.latestEditState(for: asset.id)
        XCTAssertEqual(latest?.exposure, 1.75)
    }

    @MainActor
    func testRapidChangesCoalesceToOneSave() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "coalesce")
        await vm.activate(assetId: asset.id)

        // Five rapid changes in well under the 500ms debounce.
        for value in [0.1, 0.2, 0.3, 0.4, 0.5] {
            vm.setParameter(\.exposure, value: value)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // Wait for the debounce to fire once.
        try await Task.sleep(nanoseconds: 800_000_000)

        let history = try catalog.editHistory(for: asset.id)
        XCTAssertEqual(
            history.count,
            1,
            "Rapid slider changes must coalesce to a single save version"
        )
        XCTAssertEqual(history.first?.state.exposure, 0.5)
    }

    @MainActor
    func testDeactivateCancelsPendingSave() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "deact-save")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 3.0)

        // Deactivate before the 500ms debounce fires.
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.deactivate()

        // Wait long enough that a stray save would have gone through.
        try await Task.sleep(nanoseconds: 800_000_000)

        let latest = try catalog.latestEditState(for: asset.id)
        XCTAssertNil(
            latest,
            "deactivate must cancel the pending save so nothing is persisted"
        )
    }

    @MainActor
    func testDeactivateResetsObservableState() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "deact-reset")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 2.0)
        XCTAssertEqual(vm.editState.exposure, 2.0)
        XCTAssertEqual(vm.currentAssetId, asset.id)

        vm.deactivate()

        XCTAssertNil(vm.currentAssetId)
        XCTAssertEqual(vm.editState, EditState())
        XCTAssertNil(vm.renderedImage)
    }

    // MARK: - Parameter name → keypath lookup

    func testKeyPathLookupCoversAllElevenParameters() {
        let names = [
            "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
            "temperature", "tint", "clarity", "vibrance", "saturation",
        ]
        for name in names {
            XCTAssertNotNil(
                DevelopViewModel.keyPath(forParameter: name),
                "Lookup must resolve '\(name)' to a writable key path"
            )
        }
    }

    func testKeyPathLookupReturnsNilForUnknownName() {
        XCTAssertNil(DevelopViewModel.keyPath(forParameter: "not-a-parameter"))
        XCTAssertNil(DevelopViewModel.keyPath(forParameter: "Exposure"))  // case-sensitive
    }

    // MARK: - Helper

    /// Build a viewmodel with an in-memory catalog and a single asset that
    /// has a preview on disk so `activate()` has something to load. The
    /// preview is a solid-colour JPEG at the path `PreviewStore.previewURL`
    /// expects — no real decoding needed.
    @MainActor
    private func makeViewModelWithAsset(
        hash: String
    ) async throws -> (DevelopViewModel, Asset, CatalogDatabase) {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: hash)
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 120, g: 120, b: 120)
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)
        return (vm, asset, catalog)
    }
}
