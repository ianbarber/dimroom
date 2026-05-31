import AppKit
import Catalog
import CoreGraphics
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

    // MARK: - Original→preview coordinate agreement (#376)

    /// The magnifier's headline value is that it samples the
    /// full-resolution original, not the preview — so the patch must show
    /// the *original's* pixels at the sample point, and that point must map
    /// to the same relative location whether the patch comes from the small
    /// preview or the larger original. The preview here is a neutral grey
    /// distinct from every quadrant, and the original is a four-quadrant
    /// image at 2× the preview's resolution (both 3:2). So sampling a
    /// quadrant centre proves three things at once: the patch is sourced
    /// from the original (not the grey preview), the y-axis is not flipped
    /// (top-left origin), and the x/y axes are not swapped.
    @MainActor
    func testMagnifierSamplesOriginalAtCorrectCoordinate() async throws {
        let tl = (r: UInt8(200), g: UInt8(50), b: UInt8(50))
        let tr = (r: UInt8(50), g: UInt8(200), b: UInt8(50))
        let bl = (r: UInt8(50), g: UInt8(50), b: UInt8(200))
        let br = (r: UInt8(200), g: UInt8(200), b: UInt8(50))
        let previewColor = (r: UInt8(120), g: UInt8(120), b: UInt8(120))

        let originalURL = tempCacheDir.appendingPathComponent("quadrant-original.jpg")
        try TestFixtures.writeQuadrantJPEG(
            width: 1200,
            height: 800,
            colors: (tl: tl, tr: tr, bl: bl, br: br),
            to: originalURL
        )
        let fetcher = StubOriginalFetcher(url: originalURL)
        let (vm, asset, _) = try await makeViewModel(
            hash: "mag-coord",
            fetcher: fetcher,
            previewColor: previewColor,
            previewWidth: 600,
            previewHeight: 400
        )
        await vm.activate(assetId: asset.id)

        // Show off-centre in the bottom-left quadrant. Sample-point origin
        // is top-left, so (0.25, 0.75) is left-and-down → bottom-left.
        vm.setMagnifier(visible: true, samplePoint: CGPoint(x: 0.25, y: 0.75), zoom: 2)

        // The preview shows first; wait for the original to swap in.
        let swapped = await pollUntil { !vm.magnifierUsingPreviewFallback }
        XCTAssertTrue(swapped, "original never replaced the preview fallback")

        // Patch centre = sample point = bottom-left quadrant of the
        // original, and not the grey preview.
        let blMatched = await pollUntil {
            guard let p = self.centrePixel(of: vm.magnifierImage) else { return false }
            return self.isColor(p, near: bl, tolerance: 24)
        }
        XCTAssertTrue(
            blMatched,
            "patch centre did not match the bottom-left original colour; got \(String(describing: centrePixel(of: vm.magnifierImage)))"
        )
        if let p = centrePixel(of: vm.magnifierImage) {
            XCTAssertFalse(
                isColor(p, near: previewColor, tolerance: 24),
                "patch sampled the grey preview, not the original"
            )
        }

        // Move to the top-right quadrant to pin the other axis: a single
        // y-flip or an x/y swap would fail one of the two checks.
        vm.setMagnifierSamplePoint(CGPoint(x: 0.75, y: 0.25))
        let trMatched = await pollUntil {
            guard let p = self.centrePixel(of: vm.magnifierImage) else { return false }
            return self.isColor(p, near: tr, tolerance: 24)
        }
        XCTAssertTrue(
            trMatched,
            "after moving the sample point, patch centre did not match the top-right colour; got \(String(describing: centrePixel(of: vm.magnifierImage)))"
        )
        XCTAssertFalse(vm.magnifierUsingPreviewFallback)
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(
        hash: String,
        fetcher: (any OriginalFetcher)? = nil,
        previewColor: (r: UInt8, g: UInt8, b: UInt8) = (r: 90, g: 120, b: 160),
        previewWidth: Int = 800,
        previewHeight: Int = 600
    ) async throws -> (DevelopViewModel, Asset, CatalogDatabase) {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: hash)
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: previewColor,
            width: previewWidth,
            height: previewHeight
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store, originalFetcher: fetcher)
        return (vm, asset, catalog)
    }

    /// Poll `condition` every 50ms up to `timeout`. Returns whether it ever
    /// held. Used instead of a single fixed sleep because the original
    /// swaps in — and re-renders — asynchronously after the preview shows.
    @MainActor
    private func pollUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async -> Bool {
        let iterations = max(1, Int(timeout / 0.05))
        for _ in 0..<iterations {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func isColor(
        _ p: (r: UInt8, g: UInt8, b: UInt8),
        near expected: (r: UInt8, g: UInt8, b: UInt8),
        tolerance: Int
    ) -> Bool {
        abs(Int(p.r) - Int(expected.r)) <= tolerance &&
        abs(Int(p.g) - Int(expected.g)) <= tolerance &&
        abs(Int(p.b) - Int(expected.b)) <= tolerance
    }

    /// Read the centre pixel of an `NSImage` by drawing its backing
    /// `CGImage` into a known sRGB bitmap, so the comparison is independent
    /// of the image's own colour space.
    private func centrePixel(of image: NSImage?) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let o = ((h / 2) * w + (w / 2)) * 4
        return (r: ptr[o], g: ptr[o + 1], b: ptr[o + 2])
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
