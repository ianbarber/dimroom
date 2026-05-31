import AppKit
import Catalog
import EditEngine
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

    /// Develop view with non-identity sharpening + vignette settings. Exercises
    /// the new Sharpening slider in Presence and the new Vignette group.
    @MainActor
    func test_develop_vignette_and_sharpening() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-vig-sharp")

        vm.setParameter(\.sharpening, value: 60)
        vm.setParameter(\.vignetteAmount, value: -50)
        vm.setParameter(\.vignetteRoundness, value: 70)
        vm.setParameter(\.vignetteSoftness, value: 40)
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

    /// Develop view with a non-identity luminance S-curve. Locks the
    /// sidebar Curves group rendering with active editor handles.
    @MainActor
    func test_develop_with_luminance_curve() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-lum-curve")

        vm.setCurvePoints(.luminance, points: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.10),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.90),
            CGPoint(x: 1, y: 1)
        ])
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

    /// Develop view with non-identity noise-reduction settings. Exercises
    /// the new Noise Reduction group sliders so the sidebar layout is
    /// pinned and the rendered preview reflects the NR pass.
    @MainActor
    func test_develop_noise_reduction() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-nr")

        vm.setParameter(\.luminanceNoiseReduction, value: 60)
        vm.setParameter(\.chrominanceNoiseReduction, value: 60)
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

    /// Develop view with non-identity split-toning settings. Locks the
    /// Split Toning section layout (Balance → Highlights{Hue,Sat} →
    /// Shadows{Hue,Sat}) and the rendered preview's tint.
    @MainActor
    func test_develop_split_toning() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-split-tone")

        vm.setParameter(\.splitToneHighlightHue, value: 30)
        vm.setParameter(\.splitToneHighlightSaturation, value: 50)
        vm.setParameter(\.splitToneShadowHue, value: 210)
        vm.setParameter(\.splitToneShadowSaturation, value: 50)
        vm.setParameter(\.splitToneBalance, value: 20)
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

    /// Develop view on a Drive-only asset, frozen mid-download: the
    /// indicator should overlay the preview area and the slider sidebar
    /// should be disabled (greyed). Mirrors the holding-fetcher pattern
    /// used by `LoupeSnapshotTests` so the in-flight state is captured
    /// deterministically.
    @MainActor
    func test_develop_with_download_overlay() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var asset = TestFixtures.makeAsset(hash: "snap-download")
        asset.driveFileId = "drive-id"
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 80, g: 110, b: 160),
            width: 800,
            height: 600
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)

        let release = AsyncBarrier()
        let fetcher = HoldingProgressFetcher(tick: 0.42, release: release)
        let vm = DevelopViewModel(
            catalog: catalog,
            previewStore: store,
            originalFetcher: fetcher
        )

        await vm.activate(assetId: asset.id)
        // Initial render + download flag propagation.
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

        await release.signal()
    }

    /// Develop view with non-identity geometry settings. Exercises the new
    /// Geometry group: keystone sliders pulled off zero plus both CA + lens
    /// vignette flags enabled. Pins the sidebar layout for the new group
    /// and proves the perspective transform renders into the preview.
    @MainActor
    func test_develop_geometry() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-geom")

        vm.setParameter(\.perspectiveVertical, value: 60)
        vm.setParameter(\.perspectiveHorizontal, value: -30)
        vm.setParameter(\.perspectiveRotation, value: 5)
        vm.setFlag(\.chromaticAberration, value: true)
        vm.setFlag(\.lensVignette, value: true)
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

    /// Develop view at identity values, rendered just tall enough that the
    /// Geometry section's three sliders (Vertical / Horizontal / Rotation)
    /// and two toggles (Chromatic Aberration / Lens Vignette) fit inside
    /// the visible viewport. Locks the layout of the Geometry group on its
    /// own — the existing `test_develop_geometry` exercises non-identity
    /// values but at 1024×768 the panel sits below the fold.
    ///
    /// The frame height is the smallest that keeps the full Geometry group
    /// in view: the sidebar's last content row sits at y≈1559 (the Lens
    /// Vignette toggle), so 1580 leaves a ~21px bottom margin in keeping
    /// with the sidebar's own 12px padding while trimming the dead vertical
    /// band the old 1800 frame left below the group.
    @MainActor
    func test_develop_geometry_panel() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-geom-panel")

        let image = renderFixedPixelImage(
            for: DevelopView(viewModel: vm),
            size: CGSize(width: 1024, height: 1580)
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

    /// Develop view with HSL Hue axis selected and one band pushed.
    /// Locks the new HSL section's segmented picker, the tinted slider
    /// tracks, and the slider ordering.
    @MainActor
    func test_develop_hsl_hue() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-hsl-hue")

        vm.setHSLParameter(axis: .hue, rangeIndex: 0, value: 40)
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

    /// Develop view with HSL Saturation axis selected, exercising the
    /// segmented picker's middle tab and one negative-direction slider.
    @MainActor
    func test_develop_hsl_saturation() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-hsl-sat")

        vm.setHSLParameter(axis: .saturation, rangeIndex: 3, value: -50)
        try await Task.sleep(nanoseconds: 300_000_000)

        let panel = HSLPanelView(
            selectedAxis: .saturation,
            value: { axis, idx in vm.hslValue(axis: axis, rangeIndex: idx) },
            setValue: { axis, idx, value in
                vm.setHSLParameter(axis: axis, rangeIndex: idx, value: value)
            },
            reset: { axis, idx in vm.resetHSLParameter(axis: axis, rangeIndex: idx) }
        )
        .frame(width: 256)
        .padding(12)
        .background(Color(white: 0.1))

        let image = renderFixedPixelImage(
            for: panel,
            size: CGSize(width: 280, height: 380)
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

    /// Develop view with HSL Luminance axis selected.
    @MainActor
    func test_develop_hsl_luminance() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-hsl-lum")

        vm.setHSLParameter(axis: .luminance, rangeIndex: 5, value: -30)
        try await Task.sleep(nanoseconds: 300_000_000)

        let panel = HSLPanelView(
            selectedAxis: .luminance,
            value: { axis, idx in vm.hslValue(axis: axis, rangeIndex: idx) },
            setValue: { axis, idx, value in
                vm.setHSLParameter(axis: axis, rangeIndex: idx, value: value)
            },
            reset: { axis, idx in vm.resetHSLParameter(axis: axis, rangeIndex: idx) }
        )
        .frame(width: 256)
        .padding(12)
        .background(Color(white: 0.1))

        let image = renderFixedPixelImage(
            for: panel,
            size: CGSize(width: 280, height: 380)
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


    /// Develop view with the pixel magnifier visible, centred at (0.5, 0.5)
    /// at 2:1. Locks the floating window chrome (header, zoom button,
    /// "Lower resolution" badge), the centre reticle, and the sample-region
    /// reticle drawn over the preview. With no fetcher the magnifier samples
    /// the preview, so the patch is the deterministic preview colour.
    @MainActor
    func test_develop_with_magnifier() async throws {
        let vm = try await makeActivatedViewModel(hash: "snap-magnifier")

        vm.setMagnifier(visible: true, samplePoint: CGPoint(x: 0.5, y: 0.5), zoom: 2)
        // Give the magnifier render (30ms debounce) time to publish.
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

/// Stub `OriginalFetcher` that fires one progress tick then suspends
/// until `release.signal()` so a snapshot can capture the Develop view
/// in its mid-download state.
private actor HoldingProgressFetcher: OriginalFetcher {
    private let tick: Double
    private let release: AsyncBarrier

    init(tick: Double, release: AsyncBarrier) {
        self.tick = tick
        self.release = release
    }

    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        progress?(tick)
        // Allow the @MainActor progress callback to run before the
        // snapshot reads `downloadProgress`.
        await MainActor.run { }
        await release.wait()
        return nil
    }
}

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
