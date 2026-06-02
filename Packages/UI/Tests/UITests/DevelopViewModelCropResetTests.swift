import Catalog
import CoreGraphics
import EditEngine
import Foundation
import Previews
@testable import UI
import XCTest

/// Regression for issue #239 bug 2: switching `DevelopViewModel.activate`
/// between assets must clear `cropViewModel`'s state. Without the reset
/// the overlay continues to show the prior asset's `cropRect` even when
/// the new asset has never been cropped.
final class DevelopViewModelCropResetTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-crop-reset-tests-\(UUID().uuidString)")
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

    @MainActor
    func testActivatingFreshAssetClearsLeftoverCropOverlayState() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let assetA = TestFixtures.makeAsset(hash: "crop-reset-A")
        let assetB = TestFixtures.makeAsset(hash: "crop-reset-B")
        try catalog.insertAsset(assetA)
        try catalog.insertAsset(assetB)
        try TestFixtures.placePreview(
            for: assetA,
            cacheDirectory: tempCacheDir,
            color: (r: 100, g: 100, b: 100)
        )
        try TestFixtures.placePreview(
            for: assetB,
            cacheDirectory: tempCacheDir,
            color: (r: 100, g: 100, b: 100)
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)

        // Start on A, enter crop mode, drag the crop to a non-identity
        // rect — this mimics the real-world setup where a user has
        // started a crop on one photo.
        await vm.activate(assetId: assetA.id)
        vm.enterCropMode()
        vm.cropViewModel.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        vm.cropViewModel.selectedPreset = .oneToOne
        XCTAssertTrue(vm.cropViewModel.isActive)

        // Switch to a never-cropped asset B. The overlay state must
        // snap back to identity before B's EditState is applied.
        await vm.activate(assetId: assetB.id)

        XCTAssertEqual(
            vm.cropViewModel.cropRect,
            CGRect(x: 0, y: 0, width: 1, height: 1),
            "fresh asset must show the full frame, not asset A's crop"
        )
        XCTAssertEqual(vm.cropViewModel.cropAngle, 0)
        XCTAssertEqual(vm.cropViewModel.selectedPreset, .free)
        XCTAssertFalse(vm.cropViewModel.isActive)
    }

    /// Regression: `enterCropMode` must inverse-convert the stored
    /// `cropRect` against the **saved** `cropReferenceSize`, not the
    /// currently-displayed `sourceImageSize`. When the preview has
    /// been regenerated at different dimensions between save and load
    /// (rotation, edit chain, cache invalidation), the two diverge,
    /// and using `sourceImageSize` mis-applies the Y flip — the overlay
    /// ends up anchored to the bottom-left of the frame instead of
    /// where the user actually cropped.
    @MainActor
    func testEnterCropModeUsesCropReferenceSizeNotSourceImageSize() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "crop-ref-size")
        try catalog.insertAsset(asset)
        // Preview at one resolution; saved crop at a different one.
        // 800×600 preview vs 2048×1365 reference is the realistic
        // "edited preview is smaller than the master that owned the
        // crop rect" case.
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 100, g: 100, b: 100)
        )
        let referenceSize = CGSize(width: 2048, height: 1365)
        // Crop the top-left quadrant at the reference resolution. In
        // CI bottom-left pixel coords that's (0, 682.5, 1024, 682.5).
        let savedCIPixelRect = CGRect(x: 0, y: 682.5, width: 1024, height: 682.5)
        var editState = EditState()
        editState.cropRect = savedCIPixelRect
        editState.cropReferenceSize = referenceSize
        try catalog.saveEditState(editState, for: asset.id)

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)
        await vm.activate(assetId: asset.id)
        vm.enterCropMode()

        // The saved CI-pixel rect (0, 682.5, 1024, 682.5) against the
        // 2048×1365 reference is the top-left quadrant: normalised
        // top-left (0, 0, 0.5, 0.5). Using `sourceImageSize` (the
        // smaller preview) instead would mangle the Y flip and land
        // somewhere else entirely — typically (0, ~0.16, 0.5, 0.5),
        // which visually reads as bottom-left anchoring.
        XCTAssertEqual(vm.cropViewModel.cropRect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(vm.cropViewModel.cropRect.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(vm.cropViewModel.cropRect.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(vm.cropViewModel.cropRect.height, 0.5, accuracy: 1e-9)
    }

    /// Deactivating Develop (e.g. switching to Library) must also clear
    /// the overlay state so re-entering Develop on the same asset starts
    /// from a clean slate rather than the rect carried over from the
    /// previous Develop session.
    @MainActor
    func testDeactivateClearsCropOverlayState() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "crop-reset-deact")
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 100, g: 100, b: 100)
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)

        await vm.activate(assetId: asset.id)
        vm.enterCropMode()
        vm.cropViewModel.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        vm.deactivate()

        XCTAssertEqual(
            vm.cropViewModel.cropRect,
            CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        XCTAssertFalse(vm.cropViewModel.isActive)
    }
}
