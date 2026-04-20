import AppKit
import Catalog
import EditEngine
import Foundation
import Previews
import SnapshotTesting
import SwiftUI
@testable import UI
import XCTest

final class HistogramSnapshotTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-histogram-snap-\(UUID().uuidString)")
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

    private static let overlaySize = CGSize(width: 240, height: 140)
    private static let developFrameSize = CGSize(width: 1024, height: 768)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    @MainActor
    private func renderFixedPixelImage(
        for view: some View,
        size: CGSize
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

    /// Overlay drawn from a known gradient-derived histogram. Exercises
    /// the RGB trace fill and the dark translucent background.
    @MainActor
    func test_histogram_overlay_gradient() {
        let view = HistogramOverlayView(data: Self.gradientHistogram())
            .padding(20)
            .background(Color(white: 0.05))
        let image = renderFixedPixelImage(for: view, size: Self.overlaySize)

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

    /// Overlay drawn from a clipped-highlights histogram. The highlight
    /// triangle should be visible on the right edge.
    @MainActor
    func test_histogram_overlay_highlight_clipping() {
        let view = HistogramOverlayView(data: Self.clippedHighlightsHistogram())
            .padding(20)
            .background(Color(white: 0.05))
        let image = renderFixedPixelImage(for: view, size: Self.overlaySize)

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

    /// Develop view with the histogram overlay visible in the bottom-left
    /// corner of the preview.
    @MainActor
    func test_develop_with_histogram_overlay() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-hist-on")

        let image = renderFixedPixelImage(
            for: DevelopView(viewModel: vm, showHistogram: .constant(true)),
            size: Self.developFrameSize
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

    /// Develop view with the histogram toggled off — no overlay visible.
    @MainActor
    func test_develop_with_histogram_hidden() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-hist-off")

        let image = renderFixedPixelImage(
            for: DevelopView(viewModel: vm, showHistogram: .constant(false)),
            size: Self.developFrameSize
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
        try await Task.sleep(nanoseconds: 300_000_000)
        return vm
    }

    /// A synthetic histogram that roughly resembles a well-exposed
    /// photograph — a broad midtone hump with small tails.
    private static func gradientHistogram() -> HistogramData {
        let bins = 256
        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)
        var lum = [Int](repeating: 0, count: bins)
        for i in 0..<bins {
            let centre = 128.0
            let sigma = 40.0
            let d = (Double(i) - centre) / sigma
            let base = Int(1000.0 * exp(-0.5 * d * d))
            red[i] = base
            green[i] = Int(Double(base) * 0.9)
            blue[i] = Int(Double(base) * 0.8)
            lum[i] = (red[i] + green[i] + blue[i]) / 3
        }
        return HistogramData(
            red: red,
            green: green,
            blue: blue,
            luminance: lum,
            shadowClipping: .none,
            highlightClipping: .none,
            binCount: bins
        )
    }

    /// Same hump shape, but with a spike at the last bin — enough to
    /// trigger the `.high` highlight clipping indicator.
    private static func clippedHighlightsHistogram() -> HistogramData {
        var data = gradientHistogram()
        var red = data.red
        var green = data.green
        var blue = data.blue
        red[bins - 1] = 2_000
        green[bins - 1] = 2_000
        blue[bins - 1] = 2_000
        data = HistogramData(
            red: red,
            green: green,
            blue: blue,
            luminance: data.luminance,
            shadowClipping: .none,
            highlightClipping: .high,
            binCount: data.binCount
        )
        return data
    }

    private static let bins: Int = 256
}
