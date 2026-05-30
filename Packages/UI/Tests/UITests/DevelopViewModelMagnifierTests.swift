import Catalog
import Foundation
import Previews
@testable import UI
import XCTest

final class DevelopViewModelMagnifierTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-magnifier-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

    // MARK: - Toggle

    @MainActor
    func testToggleFlipsVisibility() async throws {
        let (vm, asset, _) = try await makeViewModel(hash: "mag-toggle")
        await vm.activate(assetId: asset.id)

        XCTAssertFalse(vm.magnifierVisible)
        vm.toggleMagnifier()
        XCTAssertTrue(vm.magnifierVisible)
        vm.toggleMagnifier()
        XCTAssertFalse(vm.magnifierVisible)
    }

    @MainActor
    func testHidingClearsRenderState() async throws {
        let (vm, asset, _) = try await makeViewModel(hash: "mag-hide")
        await vm.activate(assetId: asset.id)

        vm.setMagnifierVisible(true)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNotNil(vm.magnifierImage)

        vm.setMagnifierVisible(false)
        XCTAssertNil(vm.magnifierImage)
        XCTAssertNil(vm.magnifierReticleRect)
    }

    // MARK: - setMagnifier clamping

    @MainActor
    func testSetMagnifierClampsSamplePointAndZoom() async throws {
        let (vm, asset, _) = try await makeViewModel(hash: "mag-clamp")
        await vm.activate(assetId: asset.id)

        vm.setMagnifier(visible: true, samplePoint: CGPoint(x: 2.0, y: -1.0), zoom: 9)
        XCTAssertTrue(vm.magnifierVisible)
        XCTAssertEqual(vm.magnifierSamplePoint, CGPoint(x: 1.0, y: 0.0))
        XCTAssertEqual(vm.magnifierZoom, 2)

        vm.setMagnifier(visible: true, samplePoint: CGPoint(x: 0.25, y: 0.75), zoom: 1)
        XCTAssertEqual(vm.magnifierSamplePoint, CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(vm.magnifierZoom, 1)
    }

    @MainActor
    func testCycleZoomTogglesBetweenOneAndTwo() async throws {
        let (vm, asset, _) = try await makeViewModel(hash: "mag-zoom")
        await vm.activate(assetId: asset.id)
        vm.setMagnifierVisible(true)

        XCTAssertEqual(vm.magnifierZoom, 2)
        vm.cycleMagnifierZoom()
        XCTAssertEqual(vm.magnifierZoom, 1)
        vm.cycleMagnifierZoom()
        XCTAssertEqual(vm.magnifierZoom, 2)
    }

    // MARK: - Render publishes an image + reticle

    @MainActor
    func testShowingMagnifierPublishesImageAndReticle() async throws {
        let (vm, asset, _) = try await makeViewModel(hash: "mag-render")
        await vm.activate(assetId: asset.id)

        vm.setMagnifierVisible(true)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNotNil(vm.magnifierImage)
        XCTAssertNotNil(vm.magnifierReticleRect)
    }

    // MARK: - Preview fallback flag

    @MainActor
    func testPreviewFallbackTrueWithNoFetcher() async throws {
        let (vm, asset, _) = try await makeViewModel(hash: "mag-nofetch")
        await vm.activate(assetId: asset.id)

        vm.setMagnifierVisible(true)
        try await Task.sleep(nanoseconds: 250_000_000)

        // No fetcher → magnifier samples the preview, badge shows.
        XCTAssertTrue(vm.magnifierUsingPreviewFallback)
        XCTAssertNotNil(vm.magnifierImage)
    }

    @MainActor
    func testPreviewFallbackClearsOnceOriginalLoads() async throws {
        // A stub fetcher returns a real on-disk JPEG as the "original".
        let originalURL = tempCacheDir.appendingPathComponent("original.jpg")
        try TestFixtures.writeSolidJPEG(
            width: 600,
            height: 400,
            color: (r: 200, g: 120, b: 60),
            to: originalURL
        )
        let fetcher = StubOriginalFetcher(url: originalURL)
        let (vm, asset, _) = try await makeViewModel(hash: "mag-original", fetcher: fetcher)
        await vm.activate(assetId: asset.id)

        vm.setMagnifierVisible(true)
        // First the preview shows (fallback true), then the original swaps in.
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertFalse(vm.magnifierUsingPreviewFallback)
        XCTAssertNotNil(vm.magnifierImage)
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        hash: String,
        fetcher: (any OriginalFetcher)? = nil
    ) async throws -> (DevelopViewModel, Asset, CatalogDatabase) {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: hash)
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 90, g: 120, b: 160),
            width: 800,
            height: 600
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store, originalFetcher: fetcher)
        return (vm, asset, catalog)
    }
}

/// Returns a fixed local URL as the "original" so the magnifier's
/// full-resolution path can be exercised without Drive.
private struct StubOriginalFetcher: OriginalFetcher {
    let url: URL?
    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        url
    }
}
