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

    // MARK: - Window offset clamp (#377)

    /// An offset that already keeps the whole window on-screen is returned
    /// untouched.
    func testClampedOffsetInBoundsIsUnchanged() {
        let container = CGSize(width: 1000, height: 800)
        let offset = CGSize(width: -100, height: 100)
        XCTAssertEqual(
            DevelopViewModel.clampedMagnifierOffset(offset, container: container),
            offset
        )
    }

    /// The window is anchored top-trailing, so any positive (rightward)
    /// horizontal offset is pinned to its anchor at `0`.
    func testClampedOffsetOffRightClampsToZero() {
        let container = CGSize(width: 1000, height: 800)
        let clamped = DevelopViewModel.clampedMagnifierOffset(
            CGSize(width: 5000, height: 100),
            container: container
        )
        XCTAssertEqual(clamped.width, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.height, 100, accuracy: 1e-9)
    }

    /// Dragging left is bounded by the container width so the window's left
    /// edge stops at the matching margin.
    func testClampedOffsetOffLeftClampsToContainerMinimum() {
        let container = CGSize(width: 1000, height: 800)
        let window = DevelopViewModel.magnifierWindowSize
        let pad = DevelopViewModel.magnifierWindowPadding
        let clamped = DevelopViewModel.clampedMagnifierOffset(
            CGSize(width: -5000, height: 100),
            container: container
        )
        XCTAssertEqual(clamped.width, -(container.width - window.width - 2 * pad), accuracy: 1e-9)
    }

    /// The window is anchored at the top, so any negative (upward) vertical
    /// offset is pinned to its anchor at `0`.
    func testClampedOffsetOffTopClampsToZero() {
        let container = CGSize(width: 1000, height: 800)
        let clamped = DevelopViewModel.clampedMagnifierOffset(
            CGSize(width: -100, height: -5000),
            container: container
        )
        XCTAssertEqual(clamped.height, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.width, -100, accuracy: 1e-9)
    }

    /// Dragging down is bounded by the container height so the window's
    /// bottom edge stops at the matching margin.
    func testClampedOffsetOffBottomClampsToContainerMaximum() {
        let container = CGSize(width: 1000, height: 800)
        let window = DevelopViewModel.magnifierWindowSize
        let pad = DevelopViewModel.magnifierWindowPadding
        let clamped = DevelopViewModel.clampedMagnifierOffset(
            CGSize(width: -100, height: 5000),
            container: container
        )
        XCTAssertEqual(clamped.height, container.height - window.height - 2 * pad, accuracy: 1e-9)
    }

    /// A non-positive container size means the preview hasn't laid out yet,
    /// so the offset passes through unchanged (the launch self-heal waits
    /// for the first real geometry frame).
    func testClampedOffsetUnknownContainerPassesThrough() {
        let offset = CGSize(width: 9999, height: -9999)
        XCTAssertEqual(
            DevelopViewModel.clampedMagnifierOffset(offset, container: .zero),
            offset
        )
    }

    /// When the preview is smaller than the window the travel range
    /// collapses to zero, pinning the window at its anchor.
    func testClampedOffsetTinyContainerPinsToAnchor() {
        let clamped = DevelopViewModel.clampedMagnifierOffset(
            CGSize(width: -50, height: 50),
            container: CGSize(width: 80, height: 80)
        )
        XCTAssertEqual(clamped, .zero)
    }

    @MainActor
    func testSetMagnifierWindowOffsetClampsAgainstContainer() async throws {
        let (vm, _, _) = try await makeViewModel(hash: "mag-offset-clamp")
        vm.setMagnifierContainerSize(CGSize(width: 1000, height: 800))

        vm.setMagnifierWindowOffset(CGSize(width: 5000, height: 5000))

        let window = DevelopViewModel.magnifierWindowSize
        let pad = DevelopViewModel.magnifierWindowPadding
        XCTAssertEqual(vm.magnifierWindowOffset.width, 0, accuracy: 1e-9)
        XCTAssertEqual(
            vm.magnifierWindowOffset.height,
            800 - window.height - 2 * pad,
            accuracy: 1e-9
        )
    }

    /// The launch self-heal: a stale off-screen offset (restored from
    /// Settings before the preview has reported its size) is re-clamped
    /// on-screen the moment the geometry reader supplies a real size.
    @MainActor
    func testSetMagnifierContainerSizeReclampsStaleOffset() async throws {
        let (vm, _, _) = try await makeViewModel(hash: "mag-offset-reclamp")

        // Container size unknown → the stale value passes through.
        vm.setMagnifierWindowOffset(CGSize(width: 9999, height: 9999))
        XCTAssertEqual(vm.magnifierWindowOffset, CGSize(width: 9999, height: 9999))

        // Preview lays out → offset self-heals into the visible bounds.
        vm.setMagnifierContainerSize(CGSize(width: 1000, height: 800))

        let window = DevelopViewModel.magnifierWindowSize
        let pad = DevelopViewModel.magnifierWindowPadding
        XCTAssertEqual(vm.magnifierWindowOffset.width, 0, accuracy: 1e-9)
        XCTAssertEqual(
            vm.magnifierWindowOffset.height,
            800 - window.height - 2 * pad,
            accuracy: 1e-9
        )
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

    // MARK: - Window-offset clamp invariant (#377)

    /// The safety property the issue is really about: whatever wild offset
    /// arrives, the *whole* window ends up within the container bounds. The
    /// case-by-case clamp behaviour is pinned above; this guards the
    /// invariant those cases add up to.
    func testClampKeepsWholeWindowOnScreenForWildOffsets() {
        let win = DevelopViewModel.magnifierWindowSize
        let pad = DevelopViewModel.magnifierWindowPadding
        let container = CGSize(width: 1000, height: 800)
        let wildOffsets = [
            CGSize(width: 9000, height: 9000),
            CGSize(width: -9000, height: -9000),
            CGSize(width: 9000, height: -9000),
            CGSize(width: -9000, height: 9000),
        ]
        for offset in wildOffsets {
            let c = DevelopViewModel.clampedMagnifierOffset(offset, container: container)
            // Window frame at this offset, anchored top-trailing inside `pad`.
            let left = container.width - pad - win.width + c.width
            let top = pad + c.height
            let right = left + win.width
            let bottom = top + win.height
            XCTAssertGreaterThanOrEqual(left, -0.001, "left off-screen for \(offset)")
            XCTAssertLessThanOrEqual(right, container.width + 0.001, "right off-screen for \(offset)")
            XCTAssertGreaterThanOrEqual(top, -0.001, "top off-screen for \(offset)")
            XCTAssertLessThanOrEqual(bottom, container.height + 0.001, "bottom off-screen for \(offset)")
        }
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
