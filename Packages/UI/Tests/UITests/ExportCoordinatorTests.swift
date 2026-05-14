import Catalog
import EditEngine
import Foundation
@testable import UI
import XCTest

/// Covers the on-demand-download path through `ExportCoordinator.run`:
/// when an asset has no `localPath` but a fetcher is wired, the
/// coordinator must pull the bytes and resume the regular export flow,
/// while publishing per-asset download progress for the UI overlay.
final class ExportCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
    }

    /// Asset has no localPath but the fetcher returns a real URL → the
    /// coordinator wires that URL into the export call and the file
    /// lands at the destination.
    @MainActor
    func testRunFetchesOriginalWhenLocalPathIsNil() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var asset = makeAsset(hash: "fetch-roundtrip", filename: "img.jpg")
        asset.driveFileId = "drive-id"
        // Leave localPath nil so the fetcher path is exercised.
        try catalog.insertAsset(asset)

        // Stage a real source JPEG that the fetcher will return — Exporter
        // needs valid image bytes to round-trip.
        let sourceURL = tempDir.appendingPathComponent("source.jpg")
        try writeSolidJPEG(width: 32, height: 32, to: sourceURL)

        let destination = tempDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let coordinator = ExportCoordinator()
        let fetcher = StubFetcher(url: sourceURL)

        await coordinator.run(
            assets: [asset],
            catalog: catalog,
            format: .original,
            jpegQuality: 85,
            applyEdits: false,
            destinationDirectory: destination,
            originalFetcher: fetcher
        )

        let calls = await fetcher.callCount
        XCTAssertEqual(calls, 1, "Fetcher must be called for missing-local assets")
        if case .done(let count) = coordinator.phase {
            XCTAssertEqual(count, 1, "Export must succeed using the fetched URL")
        } else {
            XCTFail("Expected .done phase, got \(coordinator.phase)")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(written.count, 1, "One file must be written to destination")
    }

    /// Fetcher fires a progress tick while suspended on a barrier; the
    /// coordinator's `currentItemProgress` should reflect that tick. Once
    /// the fetcher releases (returning nil so the asset is skipped),
    /// `currentItemProgress` must reset to nil so the next asset starts
    /// clean.
    @MainActor
    func testRunReportsCurrentItemProgressDuringDownload() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var asset = makeAsset(hash: "progress-tick", filename: "img.jpg")
        asset.driveFileId = "drive-id"
        try catalog.insertAsset(asset)

        let destination = tempDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let coordinator = ExportCoordinator()
        let release = AsyncBarrier()
        let fetcher = HoldingProgressFetcher(tick: 0.35, release: release)

        // Kick the run off in the background so we can observe the
        // intermediate state while the fetcher is paused on the barrier.
        let runTask = Task { @MainActor in
            await coordinator.run(
                assets: [asset],
                catalog: catalog,
                format: .original,
                jpegQuality: 85,
                applyEdits: false,
                destinationDirectory: destination,
                originalFetcher: fetcher
            )
        }

        // Allow the @MainActor progress callback to hop onto the actor
        // and update `currentItemProgress` before we read it.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.currentItemProgress ?? 0, 0.35, accuracy: 0.001)

        await release.signal()
        await runTask.value

        XCTAssertNil(
            coordinator.currentItemProgress,
            "currentItemProgress must reset to nil once the asset is processed"
        )
    }

    /// Without a fetcher, missing-local assets are skipped (legacy
    /// behaviour). No progress is emitted, no file is written.
    @MainActor
    func testRunSkipsMissingLocalAssetsWhenNoFetcher() async throws {
        let catalog = try CatalogDatabase.inMemory()
        var asset = makeAsset(hash: "no-fetcher")
        asset.driveFileId = "drive-id"
        try catalog.insertAsset(asset)

        let destination = tempDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let coordinator = ExportCoordinator()
        await coordinator.run(
            assets: [asset],
            catalog: catalog,
            format: .original,
            jpegQuality: 85,
            applyEdits: false,
            destinationDirectory: destination,
            originalFetcher: nil
        )

        XCTAssertNil(coordinator.currentItemProgress)
        if case .done(let count) = coordinator.phase {
            XCTAssertEqual(count, 0)
        } else {
            XCTFail("Expected .done phase")
        }
    }

    // MARK: - Helpers

    private func makeAsset(
        hash: String,
        filename: String = "test.jpg"
    ) -> Asset {
        Asset(
            contentHash: hash,
            originalFilename: filename,
            captureDate: nil,
            importedDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .digital,
            width: 32,
            height: 32,
            bytes: 1024
        )
    }

    private func writeSolidJPEG(width: Int, height: Int, to url: URL) throws {
        try TestFixtures.writeSolidJPEG(
            width: width,
            height: height,
            color: (r: 200, g: 100, b: 50),
            to: url
        )
    }
}

/// Returns the same URL for every fetch — lets the round-trip test
/// pretend the cache hit a freshly downloaded file.
private actor StubFetcher: OriginalFetcher {
    private let url: URL
    private(set) var callCount = 0

    init(url: URL) {
        self.url = url
    }

    func fetchOriginal(
        assetId: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async -> URL? {
        callCount += 1
        return url
    }
}

/// Mirrors the LoupeSnapshotTests pattern: fire a single progress tick,
/// then suspend until `release.signal()` so the caller can observe
/// the intermediate "downloading" state.
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
        // Let the Task { @MainActor in … } that the progress callback
        // hops through run before the test inspects state.
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
