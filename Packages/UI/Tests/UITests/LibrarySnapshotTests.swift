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
    private func renderFixedPixelImage(
        for view: some View,
        size: CGSize = LibrarySnapshotTests.frameSize
    ) -> NSImage {
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

    // MARK: - Ratings + filter

    /// Populated grid after the user picks min-rating = 3. Only the
    /// 3-star and 5-star cells should remain — the 1-star cell must be
    /// hidden entirely. The visible cells should show their star
    /// overlays.
    @MainActor
    func test_populated_grid_filtered_to_three_stars() async throws {
        let (vm, _) = try await makeRatedViewModel()
        await vm.setMinRating(3)
        XCTAssertEqual(vm.rows.count, 2)

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

    /// Single cell rendered in isolation at a fixed 200x200 point size
    /// so the star overlay placement is legible independently of the
    /// grid layout. Uses a 3-star asset with a pre-placed green
    /// thumbnail.
    @MainActor
    func test_library_cell_with_three_star_overlay() async throws {
        var asset = TestFixtures.makeAsset(
            hash: "starred3",
            filename: "starred.jpg"
        )
        asset.rating = 3
        try TestFixtures.placeThumbnail(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 180, b: 90)
        )
        let row = LibraryRow(
            asset: asset,
            thumbnailURL: tempCacheDir
                .appendingPathComponent("st", isDirectory: true)
                .appendingPathComponent("starred3.thumb.jpg"),
            previewURL: nil
        )

        let cell = LibraryCell(row: row, isSelected: false, rowVersion: 0)
            .frame(width: 200, height: 200)

        let image = renderFixedPixelImage(
            for: cell,
            size: CGSize(width: 200, height: 200)
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

    // MARK: - Rotated (non-square) thumbnail

    /// Grid containing one non-square thumbnail (192×256, simulating a
    /// landscape photo rotated 90°) alongside square thumbnails. The cell
    /// must remain square with the image aspect-fit inside, not overflow
    /// or distort the grid layout.
    @MainActor
    func test_populated_grid_with_rotated_thumbnail() async throws {
        let catalog = try CatalogDatabase.inMemory()

        let rotated = TestFixtures.makeAsset(
            hash: "aaaaroted",
            filename: "rotated.jpg",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        let normal1 = TestFixtures.makeAsset(
            hash: "bbbbnorm1",
            filename: "norm1.jpg",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        let normal2 = TestFixtures.makeAsset(
            hash: "ccccnorm2",
            filename: "norm2.jpg",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        try catalog.insertAsset(rotated)
        try catalog.insertAsset(normal1)
        try catalog.insertAsset(normal2)

        // Non-square thumbnail: portrait aspect from a rotated landscape
        try TestFixtures.placeThumbnail(
            for: rotated,
            cacheDirectory: tempCacheDir,
            color: (r: 210, g: 60, b: 60),
            width: 192,
            height: 256
        )
        try TestFixtures.placeThumbnail(
            for: normal1,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 180, b: 90)
        )
        try TestFixtures.placeThumbnail(
            for: normal2,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 110, b: 210)
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()

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

    // MARK: - Scope picker

    @MainActor
    func test_scope_picker_with_three_sessions() async throws {
        let (vm, _) = try await makeViewModelWithSessions()

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

    /// Three assets at ratings 1/3/5, ordered so the 5-star is newest
    /// and the 1-star is oldest. Each has a pre-placed solid-colour
    /// thumbnail so the filter snapshot exercises the star overlay and
    /// the filter bar simultaneously. Returns the view model and the
    /// three assets in newest-first order.
    @MainActor
    private func makeRatedViewModel() async throws -> (LibraryViewModel, [Asset]) {
        let catalog = try CatalogDatabase.inMemory()

        var five = TestFixtures.makeAsset(
            hash: "rate5newest",
            filename: "five.jpg",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        five.rating = 5
        var three = TestFixtures.makeAsset(
            hash: "rate3middle",
            filename: "three.jpg",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        three.rating = 3
        var one = TestFixtures.makeAsset(
            hash: "rate1oldest",
            filename: "one.jpg",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        one.rating = 1

        try catalog.insertAsset(five)
        try catalog.insertAsset(three)
        try catalog.insertAsset(one)

        try TestFixtures.placeThumbnail(
            for: five,
            cacheDirectory: tempCacheDir,
            color: (r: 210, g: 60, b: 60)
        )
        try TestFixtures.placeThumbnail(
            for: three,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 180, b: 90)
        )
        try TestFixtures.placeThumbnail(
            for: one,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 110, b: 210)
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        return (vm, [five, three, one])
    }

    /// Three import sessions each with assets and pre-placed thumbnails.
    /// Exercises the scope picker appearing in the filter bar.
    @MainActor
    private func makeViewModelWithSessions() async throws -> (LibraryViewModel, [Asset]) {
        let catalog = try CatalogDatabase.inMemory()

        let s1 = ImportSession(
            startedAt: Date(timeIntervalSince1970: 3_000_000),
            sourceKind: "folder",
            sourceDevice: "Pixii Camera"
        )
        let s2 = ImportSession(
            startedAt: Date(timeIntervalSince1970: 2_000_000),
            sourceKind: "folder",
            sourceDevice: "Canon EOS R6"
        )
        let s3 = ImportSession(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceKind: "folder"
        )
        try catalog.insertImportSession(s1)
        try catalog.insertImportSession(s2)
        try catalog.insertImportSession(s3)

        var a1 = TestFixtures.makeAsset(
            hash: "sess1newest",
            filename: "pixii.jpg",
            captureDate: Date(timeIntervalSince1970: 3_000_000)
        )
        a1.importSessionId = s1.id
        var a2 = TestFixtures.makeAsset(
            hash: "sess2middle",
            filename: "canon.jpg",
            captureDate: Date(timeIntervalSince1970: 2_000_000)
        )
        a2.importSessionId = s2.id
        var a3 = TestFixtures.makeAsset(
            hash: "sess3oldest",
            filename: "scan.jpg",
            captureDate: Date(timeIntervalSince1970: 1_000_000)
        )
        a3.importSessionId = s3.id

        try catalog.insertAsset(a1)
        try catalog.insertAsset(a2)
        try catalog.insertAsset(a3)

        try TestFixtures.placeThumbnail(
            for: a1,
            cacheDirectory: tempCacheDir,
            color: (r: 210, g: 60, b: 60)
        )
        try TestFixtures.placeThumbnail(
            for: a2,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 180, b: 90)
        )
        try TestFixtures.placeThumbnail(
            for: a3,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 110, b: 210)
        )

        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        return (vm, [a1, a2, a3])
    }
}
