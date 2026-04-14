import XCTest
@testable import DriveClient

final class OriginalsCacheTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("originals-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCacheMissTriggersDownloadAndWritesIndex() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let payload = Data(repeating: 0x1F, count: 256)
        let downloader = FakeDownloader(payloads: ["drive-1": payload])
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024 * 1024,
            downloader: downloader
        )

        let url = try await cache.fetch(
            assetId: assetId,
            driveFileId: "drive-1",
            suggestedFilename: "photo.jpg",
            progress: nil
        )

        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertTrue(url.path.hasPrefix(dir.path))
        let downloadCount = await downloader.callCount
        XCTAssertEqual(downloadCount, 1)

        // Index persisted on disk with the new entry.
        let indexData = try Data(contentsOf: dir.appendingPathComponent("index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(OriginalsCacheIndex.self, from: indexData)
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries[assetId.uuidString]?.bytes, 256)
    }

    func testCacheHitDoesNotCallDownloaderAndBumpsLastAccess() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let payload = Data(repeating: 0x2F, count: 128)
        let downloader = FakeDownloader(payloads: ["drive-hit": payload])
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_000))
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024 * 1024,
            downloader: downloader,
            clock: clock.now
        )

        _ = try await cache.fetch(
            assetId: assetId,
            driveFileId: "drive-hit",
            suggestedFilename: "a.jpg",
            progress: nil
        )
        let before = try await readIndex(at: dir).entries[assetId.uuidString]!.lastAccess
        clock.advance(by: 30)

        let hitURL = try await cache.fetch(
            assetId: assetId,
            driveFileId: "drive-hit",
            suggestedFilename: "a.jpg",
            progress: nil
        )
        XCTAssertEqual(try Data(contentsOf: hitURL), payload)
        let after = try await readIndex(at: dir).entries[assetId.uuidString]!.lastAccess
        XCTAssertGreaterThan(after, before)

        let downloadCount = await downloader.callCount
        XCTAssertEqual(downloadCount, 1)
    }

    func testCurrentSizeBytesTracksWrites() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payloadA = Data(repeating: 0x10, count: 100)
        let payloadB = Data(repeating: 0x20, count: 250)
        let downloader = FakeDownloader(payloads: ["a": payloadA, "b": payloadB])
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1_000,
            downloader: downloader
        )
        let size0 = await cache.currentSizeBytes()
        XCTAssertEqual(size0, 0)
        _ = try await cache.fetch(assetId: UUID(), driveFileId: "a", suggestedFilename: "a.jpg", progress: nil)
        let size1 = await cache.currentSizeBytes()
        XCTAssertEqual(size1, 100)
        _ = try await cache.fetch(assetId: UUID(), driveFileId: "b", suggestedFilename: "b.jpg", progress: nil)
        let size2 = await cache.currentSizeBytes()
        XCTAssertEqual(size2, 350)
    }

    func testExceedingBudgetEvictsLeastRecentlyAccessedAndFiresOnEvict() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldId = UUID()
        let midId = UUID()
        let newId = UUID()
        let payload = Data(repeating: 0xAA, count: 100)
        let downloader = FakeDownloader(payloads: [
            "old": payload,
            "mid": payload,
            "new": payload,
        ])
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_000))
        let evictions = EvictionLog()
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 200,
            downloader: downloader,
            clock: clock.now,
            onEvict: { id in evictions.record(id) }
        )

        _ = try await cache.fetch(assetId: oldId, driveFileId: "old", suggestedFilename: "old.jpg", progress: nil)
        clock.advance(by: 10)
        _ = try await cache.fetch(assetId: midId, driveFileId: "mid", suggestedFilename: "mid.jpg", progress: nil)
        clock.advance(by: 10)
        // Adding the third asset puts us over budget (300 > 200). The
        // oldest entry (oldId) should be evicted.
        _ = try await cache.fetch(assetId: newId, driveFileId: "new", suggestedFilename: "new.jpg", progress: nil)

        let size = await cache.currentSizeBytes()
        XCTAssertLessThanOrEqual(size, 200)
        let cachedOld = await cache.cachedURL(for: oldId)
        XCTAssertNil(cachedOld)
        let cachedMid = await cache.cachedURL(for: midId)
        XCTAssertNotNil(cachedMid)
        let cachedNew = await cache.cachedURL(for: newId)
        XCTAssertNotNil(cachedNew)
        XCTAssertEqual(evictions.ids, [oldId])
    }

    func testBudgetSmallerThanOneFileStillCachesTheNewFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let payload = Data(repeating: 0x33, count: 500)
        let downloader = FakeDownloader(payloads: ["only": payload])
        // Budget too small for the file — eviction should not remove the
        // entry currently being added. Otherwise the fetch is pointless.
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 10,
            downloader: downloader
        )
        let url = try await cache.fetch(
            assetId: assetId,
            driveFileId: "only",
            suggestedFilename: "only.jpg",
            progress: nil
        )
        XCTAssertEqual(try Data(contentsOf: url), payload)
        let cached = await cache.cachedURL(for: assetId)
        XCTAssertNotNil(cached)
    }

    func testConcurrentFetchSameAssetCoalescesIntoOneDownload() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let payload = Data(repeating: 0x44, count: 64)
        let downloader = SlowDownloader(payload: payload)
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024,
            downloader: downloader
        )

        async let a = cache.fetch(
            assetId: assetId, driveFileId: "f", suggestedFilename: "x.jpg", progress: nil
        )
        async let b = cache.fetch(
            assetId: assetId, driveFileId: "f", suggestedFilename: "x.jpg", progress: nil
        )
        let (urlA, urlB) = try await (a, b)
        XCTAssertEqual(urlA, urlB)
        let count = await downloader.callCount
        XCTAssertEqual(count, 1)
    }

    func testDriveHTTPErrorSurfacesDownloadFailed() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let downloader = FailingDownloader()
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024,
            downloader: downloader
        )
        do {
            _ = try await cache.fetch(
                assetId: assetId, driveFileId: "x", suggestedFilename: "x.jpg", progress: nil
            )
            XCTFail("expected downloadFailed")
        } catch OriginalsCacheError.downloadFailed(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected \(error)")
        }
        let cached = await cache.cachedURL(for: assetId)
        XCTAssertNil(cached)
        let size = await cache.currentSizeBytes()
        XCTAssertEqual(size, 0)
    }

    func testGenericDownloaderErrorSurfacesUnreachable() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let downloader = GenericFailingDownloader()
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 1024,
            downloader: downloader
        )
        do {
            _ = try await cache.fetch(
                assetId: assetId, driveFileId: "x", suggestedFilename: "x.jpg", progress: nil
            )
            XCTFail("expected unreachable")
        } catch OriginalsCacheError.unreachable {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testIndexSurvivesProcessRestart() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let assetId = UUID()
        let payload = Data(repeating: 0x55, count: 200)

        let downloader1 = FakeDownloader(payloads: ["persist": payload])
        let cache1 = try OriginalsCache(
            directory: dir,
            budgetBytes: 10_000,
            downloader: downloader1
        )
        _ = try await cache1.fetch(
            assetId: assetId, driveFileId: "persist", suggestedFilename: "x.jpg", progress: nil
        )

        // New actor, same directory — should find the existing entry
        // without issuing a fresh download.
        let downloader2 = FakeDownloader(payloads: [:])
        let cache2 = try OriginalsCache(
            directory: dir,
            budgetBytes: 10_000,
            downloader: downloader2
        )
        let cached = await cache2.cachedURL(for: assetId)
        XCTAssertNotNil(cached)
        XCTAssertEqual(try Data(contentsOf: cached!), payload)
        let size = await cache2.currentSizeBytes()
        XCTAssertEqual(size, 200)
        let c2 = await downloader2.callCount
        XCTAssertEqual(c2, 0)
    }

    func testPinnedEntriesAreNotEvicted() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pinnedId = UUID()
        let downloadId = UUID()

        // Stage a pinned file on disk as if import had just placed it.
        let sourceDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceURL = sourceDir.appendingPathComponent("imported.jpg")
        try Data(repeating: 0x01, count: 500).write(to: sourceURL)

        let payload = Data(repeating: 0x66, count: 300)
        let downloader = FakeDownloader(payloads: ["d": payload])
        let clock = AdvancingClock(start: Date(timeIntervalSince1970: 1_000))
        let evictions = EvictionLog()
        let cache = try OriginalsCache(
            directory: dir,
            budgetBytes: 400,
            downloader: downloader,
            clock: clock.now,
            onEvict: { id in evictions.record(id) }
        )

        _ = try await cache.adoptPinnedFile(assetId: pinnedId, sourceURL: sourceURL)
        clock.advance(by: 10)
        _ = try await cache.fetch(
            assetId: downloadId, driveFileId: "d", suggestedFilename: "d.jpg", progress: nil
        )

        // Pinned file must remain even though total (800) exceeds budget.
        let pinnedCached = await cache.cachedURL(for: pinnedId)
        XCTAssertNotNil(pinnedCached)
        let downloadCached = await cache.cachedURL(for: downloadId)
        XCTAssertNotNil(downloadCached)
        XCTAssertFalse(evictions.ids.contains(pinnedId))
    }

    // MARK: - Helpers

    private func readIndex(at dir: URL) async throws -> OriginalsCacheIndex {
        let data = try Data(contentsOf: dir.appendingPathComponent("index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OriginalsCacheIndex.self, from: data)
    }
}

// MARK: - Test doubles

private actor FakeDownloader: OriginalsDownloader {
    private let payloads: [String: Data]
    private(set) var callCount: Int = 0

    init(payloads: [String: Data]) {
        self.payloads = payloads
    }

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        callCount += 1
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

private actor SlowDownloader: OriginalsDownloader {
    private let payload: Data
    private(set) var callCount: Int = 0

    init(payload: Data) {
        self.payload = payload
    }

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        callCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destinationURL)
    }
}

private struct FailingDownloader: OriginalsDownloader {
    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        throw DriveClientError.downloadFailed(status: 503)
    }
}

private struct GenericFailingDownloader: OriginalsDownloader {
    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        throw NSError(domain: "test.network", code: -1009)
    }
}

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) {
        self.current = start
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
    var now: @Sendable () -> Date {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return current
        }
    }
}

private final class EvictionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID] = []
    func record(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        storage.append(id)
    }
    var ids: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
