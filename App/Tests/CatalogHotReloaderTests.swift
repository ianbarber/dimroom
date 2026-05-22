import Catalog
@testable import Dimroom
import SyncEngine
import XCTest

/// Layer A coverage for `CatalogHotReloader`, the file-swap +
/// new-catalog construction the AppDelegate's hot-reload path
/// dispatches when a delta-sync poll classifies a remote catalog change
/// (#259). Pinning the decomposable parts here keeps the swap
/// mechanics — atomic file replace, validation, sync-state stamping,
/// pending-changes bail — out of the `NSApplication`-bound AppDelegate
/// orchestration.
final class CatalogHotReloaderTests: XCTestCase {

    // MARK: - Fixture plumbing

    private func seedCatalog(
        at path: String,
        pageToken: String,
        modifiedTime: String? = nil
    ) throws {
        let db = try CatalogDatabase(path: path)
        try db.saveDrivePageToken(pageToken)
        if let modifiedTime {
            try db.saveLastPublishedCatalogModifiedTime(modifiedTime)
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogHotReloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Successful swap

    func testReloadReplacesLocalCatalogAndStampsSyncState() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let localPath = dir.appendingPathComponent("catalog.sqlite").path
        let remotePath = dir.appendingPathComponent("remote.sqlite").path

        try seedCatalog(at: localPath, pageToken: "old-token", modifiedTime: "2026-05-01T00:00:00.000Z")
        try seedCatalog(at: remotePath, pageToken: "remote-token")

        let downloader = LocalFileStubCatalogUploader(sourcePath: remotePath)
        let outcome = try await CatalogHotReloader.reload(
            localPath: localPath,
            driveFileId: "stub-id",
            modifiedTime: "2026-05-17T08:00:00.000Z",
            pageToken: "new-token",
            downloader: downloader,
            hasPendingChanges: { false }
        )

        guard case .reloaded(let newCatalog) = outcome else {
            XCTFail("expected .reloaded, got \(outcome)")
            return
        }

        // The new catalog should carry the page token and modified-time
        // we passed through. Without this stamp the next poll re-fires
        // `catalogChanged` for the same remote we just applied.
        XCTAssertEqual(try newCatalog.loadDrivePageToken(), "new-token")
        XCTAssertEqual(
            try newCatalog.loadLastPublishedCatalogModifiedTime(),
            "2026-05-17T08:00:00.000Z"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: localPath + ".reload-tmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
    }

    // MARK: - Pending-changes bail

    func testReloadBailsWhenPublisherHasPendingChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let localPath = dir.appendingPathComponent("catalog.sqlite").path
        try seedCatalog(at: localPath, pageToken: "old-token")
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: localPath))

        let downloader = ThrowingCatalogDownloader()
        let outcome = try await CatalogHotReloader.reload(
            localPath: localPath,
            driveFileId: "stub-id",
            modifiedTime: "2026-05-17T08:00:00.000Z",
            pageToken: "new-token",
            downloader: downloader,
            hasPendingChanges: { true }
        )

        XCTAssertEqual(outcome.kind, .pendingLocalChanges)
        XCTAssertEqual(downloader.downloadCallCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: localPath)),
            originalBytes
        )
    }

    // MARK: - Atomic file swap

    func testDownloadFailureLeavesLocalCatalogUntouched() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let localPath = dir.appendingPathComponent("catalog.sqlite").path
        try seedCatalog(at: localPath, pageToken: "old-token")
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: localPath))

        let downloader = ThrowingCatalogDownloader()
        do {
            _ = try await CatalogHotReloader.reload(
                localPath: localPath,
                driveFileId: "stub-id",
                modifiedTime: nil,
                pageToken: "new-token",
                downloader: downloader,
                hasPendingChanges: { false }
            )
            XCTFail("expected throw")
        } catch let error as CatalogHotReloader.ReloadError {
            guard case .downloadFailed = error else {
                XCTFail("expected .downloadFailed, got \(error)")
                return
            }
        }

        XCTAssertEqual(downloader.downloadCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localPath + ".reload-tmp"))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: localPath)),
            originalBytes
        )
    }

    func testCorruptDownloadLeavesLocalCatalogUntouched() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let localPath = dir.appendingPathComponent("catalog.sqlite").path
        let remotePath = dir.appendingPathComponent("remote.sqlite").path

        try seedCatalog(at: localPath, pageToken: "old-token")
        try Data("not a sqlite file".utf8).write(to: URL(fileURLWithPath: remotePath))

        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: localPath))
        let downloader = LocalFileStubCatalogUploader(sourcePath: remotePath)
        do {
            _ = try await CatalogHotReloader.reload(
                localPath: localPath,
                driveFileId: "stub-id",
                modifiedTime: nil,
                pageToken: "new-token",
                downloader: downloader,
                hasPendingChanges: { false }
            )
            XCTFail("expected throw")
        } catch let error as CatalogHotReloader.ReloadError {
            guard case .validationFailed = error else {
                XCTFail("expected .validationFailed, got \(error)")
                return
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: localPath + ".reload-tmp"))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: localPath)),
            originalBytes
        )
    }
}

// MARK: - Test helpers

private final class ThrowingCatalogDownloader: CatalogUploading, @unchecked Sendable {
    private(set) var downloadCallCount = 0

    func upload(
        snapshotPath: String,
        existingFileId: String?,
        photoCount: Int?
    ) async throws -> CatalogUploadResult {
        throw NSError(domain: "ThrowingCatalogDownloader.upload", code: -1)
    }

    func findExistingCatalog() async throws -> DriveCatalogRef? { nil }

    func download(fileId: String, to localPath: String) async throws -> Int64 {
        downloadCallCount += 1
        throw NSError(domain: "ThrowingCatalogDownloader.download", code: -1)
    }
}

private enum OutcomeKind: Equatable {
    case reloaded
    case pendingLocalChanges
}

private extension CatalogHotReloader.Outcome {
    var kind: OutcomeKind {
        switch self {
        case .reloaded: return .reloaded
        case .pendingLocalChanges: return .pendingLocalChanges
        }
    }
}
