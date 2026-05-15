import Catalog
import EditEngine
import Foundation
@testable import UI
import XCTest

final class ExportCoordinatorTests: XCTestCase {

    // MARK: - Fixture helpers

    private func makeCatalog() throws -> CatalogDatabase {
        try CatalogDatabase.inMemory()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a tiny valid JPEG so `Exporter.export` in `.original` mode
    /// (a straight file copy) succeeds without needing Core Image to
    /// decode a real image.
    private func writeStubJPEG(to url: URL) throws {
        let base64 = """
        /9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAP//////////////////////////////////////////\
        ////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAA\
        AAAAAAAAAAAACf/EABQBAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhADEAAAAV8H/8QAFBAAAAAAA\
        AAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8Q\
        AFAEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBA\
        QAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABCf/8QAFBE\
        BAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPxB//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBP\
        xB//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxB//9k=
        """.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: base64) else {
            throw NSError(domain: "ExportCoordinatorTests", code: 1)
        }
        try data.write(to: url)
    }

    private func makeAsset(
        filename: String = "IMG.jpg",
        localPath: String?,
        hash: String = String(repeating: "a", count: 64)
    ) -> Asset {
        Asset(
            contentHash: hash,
            originalFilename: filename,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .digital,
            width: 100,
            height: 100,
            localPath: localPath,
            bytes: 1_000
        )
    }

    // MARK: - Tests

    @MainActor
    func testEmptyAssetList_reportsDoneWithZeros() async throws {
        let catalog = try makeCatalog()
        let destination = try makeTempDirectory()
        let coordinator = ExportCoordinator()

        await coordinator.run(
            assets: [],
            catalog: catalog,
            format: .original,
            jpegQuality: 85,
            applyEdits: false,
            destinationDirectory: destination
        )

        XCTAssertEqual(coordinator.phase, .done(exported: 0, skipped: 0, failures: []))
        XCTAssertEqual(coordinator.totalItems, 0)
        XCTAssertEqual(coordinator.currentItem, 0)
    }

    @MainActor
    func testAssetWithNilLocalPathAndNoFetcher_isSkippedWithReason() async throws {
        let catalog = try makeCatalog()
        let destination = try makeTempDirectory()
        let asset = makeAsset(filename: "IMG_0001.jpg", localPath: nil)
        let coordinator = ExportCoordinator()

        await coordinator.run(
            assets: [asset],
            catalog: catalog,
            format: .original,
            jpegQuality: 85,
            applyEdits: false,
            destinationDirectory: destination
        )

        guard case .done(let exported, let skipped, let failures) = coordinator.phase else {
            XCTFail("expected .done, got \(coordinator.phase)")
            return
        }
        XCTAssertEqual(exported, 0)
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("IMG_0001.jpg"))
        XCTAssertTrue(failures[0].contains("no local copy"))
        XCTAssertNil(coordinator.currentItemProgress)
    }

    @MainActor
    func testUnwritableDestination_reportsFailed() async throws {
        let catalog = try makeCatalog()
        let coordinator = ExportCoordinator()
        let missing = URL(fileURLWithPath: "/tmp/dimroom-no-such-dir-\(UUID().uuidString)")

        let asset = makeAsset(localPath: "/tmp/does-not-matter")
        await coordinator.run(
            assets: [asset],
            catalog: catalog,
            format: .original,
            jpegQuality: 85,
            applyEdits: false,
            destinationDirectory: missing
        )

        if case .failed(let message) = coordinator.phase {
            XCTAssertTrue(message.contains(missing.path), "got: \(message)")
        } else {
            XCTFail("expected .failed, got \(coordinator.phase)")
        }
    }

    @MainActor
    func testMixedSuccessAndSkip_reportsCountsAndProgress() async throws {
        let catalog = try makeCatalog()
        let destination = try makeTempDirectory()

        let tempSource = destination
            .deletingLastPathComponent()
            .appendingPathComponent("source-\(UUID().uuidString).jpg")
        try writeStubJPEG(to: tempSource)
        let assetOK = makeAsset(filename: "OK.jpg", localPath: tempSource.path)
        let assetBad = Asset(
            contentHash: String(repeating: "b", count: 64),
            originalFilename: "BAD.jpg",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .digital,
            width: 100,
            height: 100,
            localPath: nil,
            bytes: 1_000
        )
        try catalog.insertAsset(assetOK)
        try catalog.insertAsset(assetBad)

        let coordinator = ExportCoordinator()
        await coordinator.run(
            assets: [assetOK, assetBad],
            catalog: catalog,
            format: .original,
            jpegQuality: 85,
            applyEdits: false,
            destinationDirectory: destination
        )

        guard case .done(let exported, let skipped, let failures) = coordinator.phase else {
            XCTFail("expected .done, got \(coordinator.phase)")
            return
        }
        XCTAssertEqual(exported, 1)
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("BAD.jpg"))
        XCTAssertEqual(coordinator.totalItems, 2)
        XCTAssertEqual(coordinator.currentItem, 2)

        try? FileManager.default.removeItem(at: tempSource)
        try? FileManager.default.removeItem(at: destination)
    }

    // MARK: - On-demand-download path

    /// Asset has no localPath but the fetcher returns a real URL → the
    /// coordinator wires that URL into the export call and the file
    /// lands at the destination.
    @MainActor
    func testRunFetchesOriginalWhenLocalPathIsNil() async throws {
        let catalog = try makeCatalog()
        let tempDir = try makeTempDirectory()
        var asset = makeAsset(
            filename: "img.jpg",
            localPath: nil,
            hash: String(repeating: "c", count: 64)
        )
        asset.driveFileId = "drive-id"
        try catalog.insertAsset(asset)

        let sourceURL = tempDir.appendingPathComponent("source.jpg")
        try writeStubJPEG(to: sourceURL)

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
        guard case .done(let exported, _, _) = coordinator.phase else {
            XCTFail("Expected .done phase, got \(coordinator.phase)")
            return
        }
        XCTAssertEqual(exported, 1, "Export must succeed using the fetched URL")
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
        let catalog = try makeCatalog()
        let tempDir = try makeTempDirectory()
        var asset = makeAsset(
            filename: "img.jpg",
            localPath: nil,
            hash: String(repeating: "d", count: 64)
        )
        asset.driveFileId = "drive-id"
        try catalog.insertAsset(asset)

        let destination = tempDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let coordinator = ExportCoordinator()
        let release = AsyncBarrier()
        let fetcher = HoldingProgressFetcher(tick: 0.35, release: release)

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

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.currentItemProgress ?? 0, 0.35, accuracy: 0.001)

        await release.signal()
        await runTask.value

        XCTAssertNil(
            coordinator.currentItemProgress,
            "currentItemProgress must reset to nil once the asset is processed"
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

/// Fire a single progress tick, then suspend until `release.signal()`
/// so the caller can observe the intermediate "downloading" state.
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
