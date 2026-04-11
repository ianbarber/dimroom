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

    // Snapshot tolerances are loose enough to survive cross-machine font /
    // Core Image drift between local dev boxes and the GitHub `macos-14`
    // runner (anti-aliasing, SF Symbol metrics, subpixel text rendering).
    // Tighter values worked locally but failed on CI; 0.95 matches the
    // pointfree-recommended cross-machine default.
    private static let snapshotPrecision: Float = 0.95
    private static let snapshotPerceptualPrecision: Float = 0.9

    /// Wraps a SwiftUI view in an `NSHostingView` at a fixed size and
    /// forces layout so snapshot-testing can capture a deterministic image
    /// on macOS. SwiftUI views don't snapshot directly through
    /// `swift-snapshot-testing`'s macOS strategies; going through
    /// `NSHostingView` gives us a real `NSView` we can render.
    @MainActor
    private func hostingView(for view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: Self.frameSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - Empty state

    @MainActor
    func test_empty_grid_placeholder() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        // No reload — the view model starts empty.

        let host = hostingView(for: LibraryView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: host,
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
        let host = hostingView(for: LibraryView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: host,
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

        let host = hostingView(for: LibraryView(viewModel: vm))

        runAssertSnapshot {
            assertSnapshot(
                of: host,
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
