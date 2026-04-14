import Catalog
@testable import Dimroom
import DriveClient
import Foundation
import XCTest

final class OriginalsCoordinatorTests: XCTestCase {
    func testEvictionClearsAssetLocalPath() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let catalog = try CatalogDatabase.inMemory()
        let firstId = UUID()
        let secondId = UUID()
        try catalog.insertAsset(
            Asset(
                id: firstId,
                contentHash: "hash-1",
                originalFilename: "first.jpg",
                sourceType: .digital,
                width: 100, height: 100,
                driveFileId: "drive-1",
                bytes: 0
            )
        )
        try catalog.insertAsset(
            Asset(
                id: secondId,
                contentHash: "hash-2",
                originalFilename: "second.jpg",
                sourceType: .digital,
                width: 100, height: 100,
                driveFileId: "drive-2",
                bytes: 0
            )
        )

        let firstPayload = Data(repeating: 0xAA, count: 400)
        let secondPayload = Data(repeating: 0xBB, count: 400)
        let downloader = StubDownloader(payloads: [
            "drive-1": firstPayload,
            "drive-2": secondPayload,
        ])

        let coordinator = OriginalsCoordinator(catalog: catalog)
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 500,
            downloader: downloader,
            onEvict: { [weak coordinator] id in
                coordinator?.handleEviction(assetId: id)
            }
        )
        coordinator.attach(cache: cache)

        // First fetch — catalog gets the path.
        let firstResult = await coordinator.fetchOriginal(assetId: firstId)
        let firstURL = try XCTUnwrap(firstResult)
        let firstAfterFetch = try XCTUnwrap(try catalog.fetchAsset(id: firstId))
        XCTAssertEqual(firstAfterFetch.localPath, firstURL.path)

        // Second fetch — exceeds budget (400 + 400 > 500), evicting the
        // first. The onEvict wire-up must clear Asset.localPath so export
        // re-fetches instead of reading a deleted file.
        let secondResult = await coordinator.fetchOriginal(assetId: secondId)
        XCTAssertNotNil(secondResult)

        let firstAfterEviction = try XCTUnwrap(try catalog.fetchAsset(id: firstId))
        XCTAssertNil(firstAfterEviction.localPath,
                     "evicted asset must have its localPath cleared")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path),
                       "evicted file should be removed from disk")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("originals-coord-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor StubDownloader: OriginalsDownloader {
    private let payloads: [String: Data]

    init(payloads: [String: Data]) {
        self.payloads = payloads
    }

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let data = payloads[driveFileId] else {
            throw OriginalsCacheError.unreachable
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL)
        progress?(1.0)
    }
}
