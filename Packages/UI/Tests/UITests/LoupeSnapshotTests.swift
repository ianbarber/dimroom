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
