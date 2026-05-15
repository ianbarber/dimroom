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
        // 1×1 JPEG with a white pixel. Enough bytes that the header parses
        // as a JPEG; Core Image isn't invoked by `.original` mode so this
        // suffices for the copy path.
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
        localPath: String?
    ) -> Asset {
        Asset(
            contentHash: String(repeating: "a", count: 64),
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
    }

    @MainActor
    func testUnwritableDestination_reportsFailed() async throws {
        let catalog = try makeCatalog()
        let coordinator = ExportCoordinator()
        // A path that doesn't exist — the coordinator should refuse the
        // batch up front rather than produce a per-file failure for every
        // asset.
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

        // Asset A has a valid on-disk original. B has no local path so it
        // must be skipped.
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

        // Cleanup
        try? FileManager.default.removeItem(at: tempSource)
        try? FileManager.default.removeItem(at: destination)
    }
}
