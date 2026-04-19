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

    /// The progress closure passed to `fetchOriginal` must reach the
    /// underlying downloader unchanged so the UI can render a determinate
    /// bar. The stub downloader emits 0.25 / 0.6 / 1.0; we collect them
    /// via the closure and assert the sequence round-trips.
    func testFetchOriginalForwardsProgressToDownloader() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let catalog = try CatalogDatabase.inMemory()
        let assetId = UUID()
        try catalog.insertAsset(
            Asset(
                id: assetId,
                contentHash: "hash-progress",
                originalFilename: "progress.jpg",
                sourceType: .digital,
                width: 100, height: 100,
                driveFileId: "drive-progress",
                bytes: 0
            )
        )

        let downloader = TickingStubDownloader(
            payload: Data(repeating: 0xCC, count: 16),
            ticks: [0.25, 0.6, 1.0]
        )
        let coordinator = OriginalsCoordinator(catalog: catalog)
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024,
            downloader: downloader
        )
        coordinator.attach(cache: cache)

        let collected = TickCollector()
        let url = await coordinator.fetchOriginal(
            assetId: assetId,
            progress: { @Sendable value in
                collected.append(value)
            }
        )
        XCTAssertNotNil(url)
        XCTAssertEqual(collected.values, [0.25, 0.6, 1.0])
    }

    /// The convenience overload (the legacy `fetchOriginal(assetId:)`
    /// shape used by `ExportCoordinator` and the harness) must keep
    /// returning a URL with no progress reporting — so existing call
    /// sites stay source-compatible.
    func testConvenienceFetchOriginalStillResolves() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let catalog = try CatalogDatabase.inMemory()
        let assetId = UUID()
        try catalog.insertAsset(
            Asset(
                id: assetId,
                contentHash: "hash-conv",
                originalFilename: "conv.jpg",
                sourceType: .digital,
                width: 100, height: 100,
                driveFileId: "drive-conv",
                bytes: 0
            )
        )

        let downloader = StubDownloader(payloads: [
            "drive-conv": Data(repeating: 0xDD, count: 16),
        ])
        let coordinator = OriginalsCoordinator(catalog: catalog)
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024,
            downloader: downloader
        )
        coordinator.attach(cache: cache)

        let url = await coordinator.fetchOriginal(assetId: assetId)
        XCTAssertNotNil(url)
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

/// Downloader that fires every value in `ticks` in order before writing
/// the payload — used to assert progress reporting reaches the caller's
/// closure unchanged.
private actor TickingStubDownloader: OriginalsDownloader {
    private let payload: Data
    private let ticks: [Double]

    init(payload: Data, ticks: [Double]) {
        self.payload = payload
        self.ticks = ticks
    }

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        for tick in ticks {
            progress?(tick)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destinationURL)
    }
}

/// Tiny @unchecked-Sendable bag for collecting progress values from
/// inside a @Sendable closure. The test serialises access by only
/// reading after the fetch returns.
private final class TickCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []

    func append(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }
}
