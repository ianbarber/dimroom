import AppKit
import Catalog
import Foundation
import Previews
import SwiftUI
@testable import UI
import TestSupport
import XCTest

final class LibrarySnapshotTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-ui-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempCacheDir,
            withIntermediateDirectories: true
        )
    }

    /// Running the tests with `DIMROOM_RECORD_SNAPSHOTS=1` in the
    /// environment captures fresh golden PNGs instead of asserting. Used
    /// by `.github/workflows/record-snapshots.yml` to regenerate goldens
    /// on a CI-equivalent `macos-14` runner, because local (dev machine)
    /// and CI renderings drift enough on fonts / SF Symbols / Core Image
    /// version to fail even generous tolerances.
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

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

    private static let frameSize = CGSize(width: 1024, height: 768)

    // Snapshot tolerances kept tight now that the render path is
    // backing-scale-independent (see `renderFixedPixelImage`). 0.99 /
    // 0.98 was the reviewer's original cross-machine target; we meet it
    // because the output is guaranteed to be at the same pixel
    // dimensions on every machine.
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    /// Renders the given SwiftUI view to a fixed-pixel `NSImage` so the
    /// snapshot output is identical regardless of the runner's display
    /// backing scale factor. The previous implementation wrapped the
    /// view in an `NSHostingView` and relied on
    /// `bitmapImageRepForCachingDisplay`, which multiplies the backing
    /// store by whatever `NSScreen` reports — 1.0 on a headless CI Mac,
    /// 1.5 on some virtualized runners, 2.0 on a Retina dev box. By
    /// building the `NSBitmapImageRep` ourselves with an explicit pixel
    /// size we pin the output to exactly `frameSize` pixels on every
    /// machine.
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
        // cacheDisplay(in:to:) draws the view into the rep at exactly
        // the rep's pixel dimensions, ignoring display scale.
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Empty state

    @MainActor
    func test_empty_grid_placeholder() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        // No reload — the view model starts empty.

        let image = renderFixedPixelImage(for: LibraryView(viewModel: vm))

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

    // MARK: - Populated grid

    @MainActor
    func test_populated_grid_no_selection() async throws {
        let (vm, _) = try await makePopulatedViewModel()
        let image = renderFixedPixelImage(for: LibraryView(viewModel: vm))

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

    @MainActor
    func test_populated_grid_second_cell_selected() async throws {
        let (vm, assets) = try await makePopulatedViewModel()
        // Assets are inserted in newest-first order in the helper, so the
        // second row in the grid is the middle asset.
        vm.select(assets[1].id)

        let image = renderFixedPixelImage(for: LibraryView(viewModel: vm))

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

    // MARK: - Helper

    /// Builds a view model backed by three fixture assets with
    /// pre-placed solid-colour thumbnails. Returns the view model and
    /// the assets in the same order the grid will render them
    /// (newest first).
    @MainActor
    private func makePopulatedViewModel() async throws -> (LibraryViewModel, [Asset]) {
        let catalog = try CatalogDatabase.inMemory()

        // Deterministic dates so the sort order is stable and obvious.
        let newest = TestFixtures.makeAsset(
            hash: "aaaanewest",
            filename: "new.jpg",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        let middle = TestFixtures.makeAsset(
            hash: "bbbbmiddle",
            filename: "mid.jpg",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        let oldest = TestFixtures.makeAsset(
            hash: "ccccoldest",
            filename: "old.jpg",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog.insertAsset(newest)
        try catalog.insertAsset(middle)
        try catalog.insertAsset(oldest)

        try TestFixtures.placeThumbnail(
            for: newest,
            cacheDirectory: tempCacheDir,
            color: (r: 210, g: 60, b: 60)
        )
        try TestFixtures.placeThumbnail(
            for: middle,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 180, b: 90)
        )
        try TestFixtures.placeThumbnail(
            for: oldest,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 110, b: 210)
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        return (vm, [newest, middle, oldest])
    }
}
