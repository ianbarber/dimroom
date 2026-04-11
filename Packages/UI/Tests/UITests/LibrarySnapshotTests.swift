import AppKit
import Catalog
import Foundation
import Previews
import SwiftUI
@testable import UI
import TestSupport
import XCTest

@MainActor
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

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

    private static let frameSize = CGSize(width: 1024, height: 768)

    /// Wraps a SwiftUI view in an `NSHostingView` at a fixed size and
    /// forces layout so snapshot-testing can capture a deterministic image
    /// on macOS. SwiftUI views don't snapshot directly through
    /// `swift-snapshot-testing`'s macOS strategies; going through
    /// `NSHostingView` gives us a real `NSView` we can render.
    private func hostingView(for view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: Self.frameSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - Empty state

    func test_empty_grid_placeholder() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        // No reload — the view model starts empty.

        let host = hostingView(for: LibraryView(viewModel: vm))

        assertSnapshot(
            of: host,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.98
            )
        )
    }

    // MARK: - Populated grid

    func test_populated_grid_no_selection() async throws {
        let (vm, _) = try makePopulatedViewModel()
        let host = hostingView(for: LibraryView(viewModel: vm))

        assertSnapshot(
            of: host,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.98
            )
        )
    }

    func test_populated_grid_second_cell_selected() async throws {
        let (vm, assets) = try makePopulatedViewModel()
        // Assets are inserted in newest-first order in the helper, so the
        // second row in the grid is the middle asset.
        vm.select(assets[1].id)

        let host = hostingView(for: LibraryView(viewModel: vm))

        assertSnapshot(
            of: host,
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.98
            )
        )
    }

    // MARK: - Helper

    /// Builds a view model backed by three fixture assets with
    /// pre-placed solid-colour thumbnails. Returns the view model and
    /// the assets in the same order the grid will render them
    /// (newest first).
    private func makePopulatedViewModel() throws -> (LibraryViewModel, [Asset]) {
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
        vm.reload()
        return (vm, [newest, middle, oldest])
    }
}
