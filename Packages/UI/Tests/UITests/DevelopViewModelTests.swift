import Catalog
import CryptoKit
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

    @MainActor
    func testResetParameterRestoresIdentityForAllSliders() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "reset-all")
        await vm.activate(assetId: asset.id)

        let names = [
            "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
            "temperature", "tint", "clarity", "sharpening", "vibrance", "saturation",
            "vignetteAmount", "vignetteRoundness", "vignetteSoftness",
        ]

        for name in names {
            guard let keyPath = DevelopViewModel.keyPath(forParameter: name) else {
                XCTFail("No keypath for parameter '\(name)'")
                continue
            }

            let identity: Double
            switch name {
            case "temperature": identity = 6500
            case "vignetteRoundness", "vignetteSoftness": identity = 50
            default: identity = 0
            }
            let nudged: Double = (name == "temperature") ? 3500 : 17

            vm.setParameter(keyPath, value: nudged)
            XCTAssertEqual(
                vm.editState[keyPath: keyPath],
                nudged,
                "Setter failed for '\(name)'"
            )

            vm.resetParameter(keyPath)
            XCTAssertEqual(
                vm.editState[keyPath: keyPath],
                identity,
                "resetParameter did not restore identity for '\(name)'"
            )
        }
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
    func testDeactivateFlushesPendingSave() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "deact-save")
        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 3.0)

        // Deactivate before the 500ms debounce fires — the pending edit
        // must be flushed, not dropped.
        try await Task.sleep(nanoseconds: 100_000_000)
        vm.deactivate()

        let latest = try catalog.latestEditState(for: asset.id)
        XCTAssertEqual(
            latest?.exposure,
            3.0,
            "deactivate must flush the pending edit to the catalog"
        )
    }

    @MainActor
    func testDeactivateWithNoPendingChangesDoesNotWrite() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "deact-clean")
        await vm.activate(assetId: asset.id)

        // No setParameter calls — viewmodel is clean.
        vm.deactivate()

        let history = try catalog.editHistory(for: asset.id)
        XCTAssertEqual(
            history.count,
            0,
            "Clean deactivate must not create a catalog version"
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

    // MARK: - Undo integration

    @MainActor
    func testSetParameterPushesEditSaveAfterDebounce() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "undo-push")
        let stack = UndoStack(catalog: catalog)
        vm.attach(undoStack: stack)
        stack.attach(developViewModel: vm)

        await vm.activate(assetId: asset.id)
        XCTAssertFalse(stack.canUndo)

        vm.setParameter(\.exposure, value: 1.25)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(stack.canUndo, "setParameter must push an undo entry after debounce")
        XCTAssertEqual(stack.undoDescription, "Exposure +1.25")
    }

    @MainActor
    func testRapidSetParameterCoalescesToOneUndoEntry() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "undo-coalesce")
        let stack = UndoStack(catalog: catalog)
        vm.attach(undoStack: stack)
        stack.attach(developViewModel: vm)

        await vm.activate(assetId: asset.id)

        for value in [0.1, 0.2, 0.3, 0.4, 0.5] {
            vm.setParameter(\.exposure, value: value)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(stack.canUndo)
        await stack.undo()
        XCTAssertFalse(
            stack.canUndo,
            "A coalesced slider drag must land as exactly one undo entry"
        )
    }

    @MainActor
    func testUndoAfterSetParameterRestoresSliderValueAndCatalog() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "undo-round-trip")
        let stack = UndoStack(catalog: catalog)
        vm.attach(undoStack: stack)
        stack.attach(developViewModel: vm)

        await vm.activate(assetId: asset.id)

        vm.setParameter(\.exposure, value: 2.0)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(vm.editState.exposure, 2.0)

        await stack.undo()
        XCTAssertEqual(
            vm.editState.exposure,
            0.0,
            "undo must restore the in-memory editState so sliders reflect it"
        )
        let catalogExposure = try catalog.latestEditState(for: asset.id)?.exposure ?? -1
        XCTAssertEqual(catalogExposure, 0.0, "undo must write the previous state to the catalog")
    }

    @MainActor
    func testRedoAfterUndoReappliesEditState() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "undo-redo")
        let stack = UndoStack(catalog: catalog)
        vm.attach(undoStack: stack)
        stack.attach(developViewModel: vm)

        await vm.activate(assetId: asset.id)
        vm.setParameter(\.exposure, value: 1.5)
        try await Task.sleep(nanoseconds: 800_000_000)

        await stack.undo()
        XCTAssertEqual(vm.editState.exposure, 0.0)

        await stack.redo()
        XCTAssertEqual(
            vm.editState.exposure,
            1.5,
            "redo must re-apply the forward state to the live view model"
        )
    }

    // MARK: - Hydration on activate

    @MainActor
    func testActivateHydratesUndoStackFromEditHistory() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "undo-hydrate")
        let stack = UndoStack(catalog: catalog)
        vm.attach(undoStack: stack)
        stack.attach(developViewModel: vm)

        var v1 = EditState(); v1.exposure = 0.5
        var v2 = EditState(); v2.exposure = 1.0
        var v3 = EditState(); v3.exposure = 1.5
        _ = try catalog.saveEditState(v1, for: asset.id)
        _ = try catalog.saveEditState(v2, for: asset.id)
        _ = try catalog.saveEditState(v3, for: asset.id)

        XCTAssertFalse(stack.canUndo)

        await vm.activate(assetId: asset.id)

        XCTAssertTrue(
            stack.canUndo,
            "activate must hydrate the undo stack from persisted edit history"
        )

        await stack.undo()
        XCTAssertEqual(
            vm.editState.exposure,
            1.0,
            "first undo after hydration must roll back to v2"
        )
        await stack.undo()
        XCTAssertEqual(
            vm.editState.exposure,
            0.5,
            "second undo after hydration must roll back to v1"
        )
        await stack.undo()
        XCTAssertEqual(
            vm.editState.exposure,
            0.0,
            "last undo after hydration must roll back to identity (nil previous)"
        )
    }

    @MainActor
    func testReactivatingSameAssetDoesNotDoubleHydrate() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "undo-no-rehydrate")
        let stack = UndoStack(catalog: catalog)
        vm.attach(undoStack: stack)
        stack.attach(developViewModel: vm)

        var saved = EditState()
        saved.exposure = 0.75
        _ = try catalog.saveEditState(saved, for: asset.id)

        await vm.activate(assetId: asset.id)
        vm.deactivate()
        await vm.activate(assetId: asset.id)

        var count = 0
        while stack.canUndo {
            await stack.undo()
            count += 1
            if count > 5 {
                XCTFail("Re-activation hydrated history more than once; got \(count) entries")
                return
            }
        }
        XCTAssertEqual(
            count,
            1,
            "re-activation must not double-hydrate the stack"
        )
    }

    // MARK: - Reload for undo/redo replay

    @MainActor
    func testReloadEditStateUpdatesEditStateFromCatalog() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "reload-from-catalog")
        await vm.activate(assetId: asset.id)

        // Out-of-band catalog write — simulates what UndoStack does on
        // an editSave replay.
        var restored = EditState()
        restored.exposure = 1.5
        restored.contrast = 40
        _ = try catalog.saveEditState(restored, for: asset.id)

        XCTAssertEqual(vm.editState.exposure, 0)

        await vm.reloadEditState(for: asset.id)

        XCTAssertEqual(vm.editState.exposure, 1.5)
        XCTAssertEqual(vm.editState.contrast, 40)
    }

    @MainActor
    func testReloadEditStateBumpsReplaySequence() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "replay-seq")
        await vm.activate(assetId: asset.id)

        let startSeq = vm.replaySequence
        await vm.reloadEditState(for: asset.id)
        XCTAssertEqual(vm.replaySequence, startSeq + 1)

        await vm.reloadEditState(for: asset.id)
        XCTAssertEqual(vm.replaySequence, startSeq + 2)
    }

    @MainActor
    func testReloadEditStateIsNoOpForWrongAssetId() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "reload-wrong-asset")
        await vm.activate(assetId: asset.id)

        let startSeq = vm.replaySequence
        await vm.reloadEditState(for: UUID())

        XCTAssertEqual(
            vm.replaySequence,
            startSeq,
            "reloadEditState must not bump replaySequence for a different asset"
        )
    }

    @MainActor
    func testReloadEditStateDoesNotScheduleSave() async throws {
        let (vm, asset, catalog) = try await makeViewModelWithAsset(hash: "reload-no-save")
        await vm.activate(assetId: asset.id)

        // Prime catalog with a state that reloadEditState will pick up.
        var primed = EditState()
        primed.exposure = 2.0
        _ = try catalog.saveEditState(primed, for: asset.id)

        await vm.reloadEditState(for: asset.id)

        // Wait past the debounce window. If reloadEditState had
        // (incorrectly) scheduled a save, a second history row would
        // appear.
        try await Task.sleep(nanoseconds: 800_000_000)

        let history = try catalog.editHistory(for: asset.id)
        XCTAssertEqual(
            history.count,
            1,
            "reloadEditState must not schedule a save — the catalog write belongs to whoever is replaying"
        )
    }

    // MARK: - Thumbnail regeneration after save

    /// After the auto-save debounce fires, the cached thumbnail must be
    /// (re)written via EditEngine — that's how Library/Loupe pick up the
    /// edited look. Placing a pre-existing thumbnail proves the bytes
    /// actually change rather than getting populated for the first time.
    @MainActor
    func testAutoSaveRegeneratesThumbnail() async throws {
        let (vm, asset, _) = try await makeViewModelWithAsset(hash: "regen-thumb-afteredit")
        try TestFixtures.placeThumbnail(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 120, g: 120, b: 120)
        )

        await vm.activate(assetId: asset.id)

        let thumbURL = tempCacheDir
            .appendingPathComponent(String(asset.contentHash.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(asset.contentHash).thumb.jpg")
        let hashBefore = try Self.sha256(of: thumbURL)

        vm.setParameter(\.exposure, value: 2.0)

        // Debounce is 500ms; wait 1.5s for the save + async regenerate
        // to land.
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let hashAfter = try Self.sha256(of: thumbURL)
        XCTAssertNotEqual(
            hashBefore,
            hashAfter,
            "Cached thumbnail bytes must change after auto-save completes"
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Parameter name → keypath lookup

    func testKeyPathLookupCoversAllParameters() {
        let names = [
            "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
            "temperature", "tint", "clarity", "sharpening", "vibrance", "saturation",
            "vignetteAmount", "vignetteRoundness", "vignetteSoftness",
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
