import AppKit
import Catalog
import Foundation
import Previews
import SnapshotTesting
import SwiftUI
@testable import UI
import XCTest

final class DevelopSnapshotTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-develop-snap-\(UUID().uuidString)")
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
    private func renderFixedPixelImage(
        for view: some View,
        size: CGSize = DevelopSnapshotTests.frameSize
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
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Snapshots

    /// Develop view at identity — all sliders centred, preview reflects
    /// the unmodified source image.
    @MainActor
    func test_develop_identity() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-identity")

        let image = renderFixedPixelImage(for: DevelopView(viewModel: vm))

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

    /// Develop view with exposure pushed to +2.0. The exposure slider is
    /// shifted right and the preview is visibly brighter.
    @MainActor
    func test_develop_exposure_plus2() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-exp2")

        vm.setParameter(\.exposure, value: 2.0)
        // Give the debounced render time to publish.
        try await Task.sleep(nanoseconds: 300_000_000)

        let image = renderFixedPixelImage(for: DevelopView(viewModel: vm))

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

    /// Develop view with no selected asset — placeholder state.
    @MainActor
    func test_develop_empty_placeholder() async throws {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)
        // No activate — view shows "Select a photo first" empty state.

        let image = renderFixedPixelImage(for: DevelopView(viewModel: vm))

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

    // MARK: - Helpers

    @MainActor
    private func makeActivatedViewModel(hash: String) async throws -> DevelopViewModel {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: hash)
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 80, g: 110, b: 160),
            width: 800,
            height: 600
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)
        await vm.activate(assetId: asset.id)
        // Let the initial render publish the NSImage.
        try await Task.sleep(nanoseconds: 300_000_000)
        return vm
    }
}
