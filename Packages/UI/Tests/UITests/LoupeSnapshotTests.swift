import AppKit
import Catalog
import Foundation
import Previews
import SwiftUI
@testable import UI
import TestSupport
import XCTest

/// Snapshot coverage for `LoupeView`. Mirrors the rendering pattern
/// established by `LibrarySnapshotTests` — fixed-pixel bitmap rendering,
/// record-mode via `DIMROOM_RECORD_SNAPSHOTS=1`, tight precision. The
/// preview JPEGs that the Loupe view loads are pre-placed via
/// `TestFixtures.placePreview` so no Core Image decode runs from within
/// the test process.
final class LoupeSnapshotTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-ui-loupe-snap-\(UUID().uuidString)")
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

    private static let snapshotRecordMode: SnapshotTestingConfiguration.Record? = {
        if ProcessInfo.processInfo.environment["DIMROOM_RECORD_SNAPSHOTS"] == "1" {
            return .all
        }
        return nil
    }()

    private func runAssertSnapshot(_ body: () -> Void) {
        if let recordMode = Self.snapshotRecordMode {
            withSnapshotTesting(record: recordMode) {
                body()
            }
        } else {
            body()
        }
    }

    private static let frameSize = CGSize(width: 1024, height: 768)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    @MainActor
    private func renderFixedPixelImage(for view: some View) -> NSImage {
        let size = Self.frameSize
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            fatalError("Failed to allocate NSBitmapImageRep for snapshot")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Placeholder (no selection)

    @MainActor
    func test_loupe_no_selection() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)

        let image = renderFixedPixelImage(for: LoupeView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Populated with fixture asset

    @MainActor
    func test_loupe_with_fixture_asset() async throws {
        let catalog = try CatalogDatabase.inMemory()

        // A landscape-ish preview, so aspect-fit lands letterboxed at
        // top and bottom — this is the most common real-world case and
        // makes it visually obvious whether the fit-to-window math is
        // working.
        let asset = TestFixtures.makeAsset(
            hash: "loupefixture",
            filename: "loupe.jpg",
            captureDate: Date(timeIntervalSince1970: 2_500_000)
        )
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 140, b: 200),
            width: 1600,
            height: 1000
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        vm.select(asset.id)

        let image = renderFixedPixelImage(for: LoupeView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Zoom indicator at fit

    @MainActor
    func test_loupe_zoom_indicator_fit() async throws {
        let catalog = try CatalogDatabase.inMemory()

        let asset = TestFixtures.makeAsset(
            hash: "zoomFit",
            filename: "zoom_fit.jpg",
            captureDate: Date(timeIntervalSince1970: 2_500_000)
        )
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 140, b: 200),
            width: 1600,
            height: 1000
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        vm.select(asset.id)

        // initialZoomScale 0 → effectiveZoomScale resolves to fit; indicator forced visible.
        let image = renderFixedPixelImage(
            for: LoupeView(viewModel: vm, initialZoomScale: 0)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Zoom indicator at 100%

    @MainActor
    func test_loupe_zoom_indicator_100() async throws {
        let catalog = try CatalogDatabase.inMemory()

        let asset = TestFixtures.makeAsset(
            hash: "zoom100",
            filename: "zoom_100.jpg",
            captureDate: Date(timeIntervalSince1970: 2_500_000)
        )
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 140, b: 200),
            width: 1600,
            height: 1000
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        vm.select(asset.id)

        // initialZoomScale 1.0 → 100% zoom; indicator forced visible.
        let image = renderFixedPixelImage(
            for: LoupeView(viewModel: vm, initialZoomScale: 1.0)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }

    // MARK: - Rotated asset

    /// Fixture with `rotation = 90` persisted in the catalog. The
    /// `PreviewStore.applyRotation` math already bakes orientation into
    /// the encoded JPEG when `generate` runs, but this test doesn't
    /// call generate — it hand-places a *portrait-shaped* preview JPEG
    /// to stand in for the rotated output. This keeps the snapshot
    /// deterministic regardless of Core Image's rotation matrix in the
    /// test environment.
    // MARK: - Download overlay (determinate)

    /// Stage a fetch via a stub that emits a single `0.42` tick and
    /// pauses indefinitely. While the fetch is in-flight, snapshot the
    /// Loupe so the determinate progress bar renders. The fetch is
    /// released after the snapshot so the test exits cleanly.
    @MainActor
    func test_loupe_with_download_overlay() async throws {
        let catalog = try CatalogDatabase.inMemory()

        let asset = TestFixtures.makeAsset(
            hash: "loupeDownload",
            filename: "loupe_download.jpg",
            captureDate: Date(timeIntervalSince1970: 2_500_000)
        )
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 140, b: 200),
            width: 1600,
            height: 1000
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        vm.select(asset.id)

        let release = AsyncBarrier()
        let started = AsyncBarrier()
        let fetcher = HoldingProgressFetcher(
            tick: 0.42,
            started: started,
            release: release
        )
        vm.originalFetcher = fetcher

        let task = Task { @MainActor in
            await vm.fetchOriginalIfNeeded(assetId: asset.id)
        }
        // Wait until the fetcher has both fired its progress tick and
        // suspended on the release barrier — at this point the view
        // model's downloadingAssetIds + downloadProgressByAssetId entry
        // are both populated for `asset.id`.
        await started.wait()
        // Drain any remaining queued main-actor progress writes.
        await MainActor.run { }

        let image = renderFixedPixelImage(for: LoupeView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }

        await release.signal()
        _ = await task.value
    }

    // MARK: - Rotated asset

    /// Fixture with `rotation = 90` persisted in the catalog. The
    /// `PreviewStore.applyRotation` math already bakes orientation into
    /// the encoded JPEG when `generate` runs, but this test doesn't
    /// call generate — it hand-places a *portrait-shaped* preview JPEG
    /// to stand in for the rotated output. This keeps the snapshot
    /// deterministic regardless of Core Image's rotation matrix in the
    /// test environment.
    @MainActor
    func test_loupe_rotated_asset() async throws {
        let catalog = try CatalogDatabase.inMemory()

        var asset = TestFixtures.makeAsset(
            hash: "loupeRotated",
            filename: "rotated.jpg",
            captureDate: Date(timeIntervalSince1970: 2_500_000)
        )
        asset.rotation = 90
        try catalog.insertAsset(asset)
        // Portrait-shape preview so the loupe's aspect-fit letterboxes
        // left/right instead of top/bottom — the obvious visual
        // difference from `test_loupe_with_fixture_asset`.
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 200, g: 140, b: 60),
            width: 1000,
            height: 1600
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        vm.select(asset.id)

        let image = renderFixedPixelImage(for: LoupeView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }
}

/// Stub `OriginalFetcher` that fires a single progress tick, signals
/// `started` once the view-model has had a chance to record it, and
/// then suspends until `release` is signalled. Lets snapshot tests
/// freeze the Loupe in the "download in flight" state.
private actor HoldingProgressFetcher: OriginalFetcher {
    private let tick: Double
    private let started: AsyncBarrier
    private let release: AsyncBarrier

    init(tick: Double, started: AsyncBarrier, release: AsyncBarrier) {
        self.tick = tick
        self.started = started
        self.release = release
    }

    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        progress?(tick)
        // Allow the Task { @MainActor in … } scheduled by progress() to
        // run before the test inspects the view model.
        await MainActor.run { }
        await started.signal()
        await release.wait()
        return nil
    }
}

/// Tiny one-shot async barrier — `wait()` blocks until `signal()` is
/// called once. Multiple `signal()` calls are no-ops; multiple waiters
/// all resume on signal.
private actor AsyncBarrier {
    private var hasSignalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if hasSignalled { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        guard !hasSignalled else { return }
        hasSignalled = true
        for continuation in continuations {
            continuation.resume()
        }
        continuations.removeAll()
    }
}
