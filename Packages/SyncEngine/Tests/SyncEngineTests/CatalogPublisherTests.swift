import XCTest
import Catalog
import GRDB
@testable import SyncEngine

final class CatalogPublisherTests: XCTestCase {

    // MARK: - Helpers

    private func makeOnDiskCatalog() throws -> (CatalogDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-publisher-\(UUID().uuidString)")
            .appendingPathComponent("catalog.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try CatalogDatabase(path: url.path)
        return (db, url)
    }

    private func snapshotDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-snapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func successResult(
        id: String = "drive-file-1",
        bytes: Int64 = 1024,
        create: Bool = true
    ) -> CatalogUploadResult {
        CatalogUploadResult(driveFileId: id, uploadedBytes: bytes, wasCreate: create)
    }

    // MARK: - Debounce

    func testDebounceCollapsesRapidTriggersIntoOneUpload() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .milliseconds(80),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        for _ in 0..<8 {
            publisher.scheduleDebouncedPublish()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(uploader.uploadCallCount, 1)
    }

    func testMaxIntervalCeilingForcesPublishUnderContinuousTriggers() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .milliseconds(500),
            maxDebounceInterval: .milliseconds(150)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        let stop = Date().addingTimeInterval(0.3)
        while Date() < stop {
            publisher.scheduleDebouncedPublish()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThanOrEqual(uploader.uploadCallCount, 1)
    }

    // MARK: - publishNow

    func testPublishNowRunsInlineEvenWithPendingDebounce() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .seconds(5),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        // Arm the debouncer (would not fire for 5 seconds), then force.
        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(20))

        let outcome = try await publisher.publishNow()
        XCTAssertEqual(uploader.uploadCallCount, 1)
        XCTAssertEqual(outcome.driveFileId, "drive-file-1")
        XCTAssertTrue(outcome.wasCreate)

        // The pending debounce should have been cancelled — no second
        // upload should land in the next 200 ms.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(uploader.uploadCallCount, 1, "publishNow must cancel the pending debounce")
    }

    func testPublishNowReusesCachedFileIdOnSubsequentCalls() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(
            behavior: .sequence([
                .success(successResult(id: "first", create: true)),
                .success(successResult(id: "first", create: false)),
            ])
        )
        let fileIdStore = InMemoryDriveFileIdStore()
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: fileIdStore,
            snapshotDirectory: snapshotDir(),
            debounceInterval: .seconds(5),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        let first = try await publisher.publishNow()
        XCTAssertNil(uploader.uploadCalls.first?.existingFileId)
        XCTAssertEqual(first.wasCreate, true)
        XCTAssertEqual(try fileIdStore.load(), "first")

        let second = try await publisher.publishNow()
        XCTAssertEqual(uploader.uploadCalls.last?.existingFileId, "first")
        XCTAssertEqual(second.wasCreate, false)
    }

    // MARK: - Error paths

    func testSnapshotFailureMapsToSnapshotFailedError() async throws {
        // Build a publisher whose catalog cannot snapshot — `VACUUM INTO`
        // fails if the destination directory cannot be created. Point the
        // snapshot dir at a path under a regular file so mkdir errors.
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let blockingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-block-\(UUID().uuidString)")
        try Data("blocker".utf8).write(to: blockingFile)
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        // Snapshot dir below a regular file → createDirectory fails.
        let badSnapshotDir = blockingFile.appendingPathComponent("nope")

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: badSnapshotDir,
            debounceInterval: .seconds(5),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        do {
            _ = try await publisher.publishNow()
            XCTFail("expected snapshot failure")
        } catch let error as SyncEngineError {
            switch error {
            case .snapshotFailed:
                break
            default:
                XCTFail("expected .snapshotFailed, got \(error)")
            }
        }
        // The upload must never have been attempted.
        XCTAssertEqual(uploader.uploadCallCount, 0)
    }

    func testUploadFailureMapsToUploadFailedError() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(
            behavior: .alwaysFail(.uploadFailed(underlying: "boom"))
        )
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .seconds(5),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        do {
            _ = try await publisher.publishNow()
            XCTFail("expected upload failure")
        } catch let error as SyncEngineError {
            switch error {
            case .uploadFailed:
                break
            default:
                XCTFail("expected .uploadFailed, got \(error)")
            }
        }
    }

    func testUploadFailureLeavesDebouncerReadyForNextTrigger() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(
            behavior: .sequence([
                .failure(.uploadFailed(underlying: "transient")),
                .success(successResult()),
            ])
        )
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .milliseconds(80),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        // First trigger fails internally — debounced publish swallows
        // errors. After the failure the debouncer must accept a fresh
        // trigger.
        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(uploader.uploadCallCount, 1)

        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(uploader.uploadCallCount, 2)
    }

    // MARK: - setEnabled / setDebounceInterval

    func testSetEnabledFalseCancelsPendingDebounce() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .milliseconds(120),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(20))
        await publisher.setEnabled(false)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(uploader.uploadCallCount, 0, "setEnabled(false) must cancel in-flight debounce")

        // Further triggers while disabled stay no-ops.
        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(uploader.uploadCallCount, 0)

        // Re-enable; a fresh trigger should publish now.
        await publisher.setEnabled(true)
        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(uploader.uploadCallCount, 1)
    }

    func testSetDebounceIntervalAppliesToNextTrigger() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .seconds(2),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        defer { Task { await publisher.stop() } }

        // Shorten to 80 ms; the next trigger should fire fast enough
        // that we observe an upload inside the 300 ms window below.
        await publisher.setDebounceInterval(.milliseconds(80))
        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(uploader.uploadCallCount, 1)
    }

    // MARK: - Idempotency

    func testStartIsIdempotent() async throws {
        let (db, url) = try makeOnDiskCatalog()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(successResult()))
        let publisher = CatalogPublisher(
            catalog: db,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            snapshotDirectory: snapshotDir(),
            debounceInterval: .milliseconds(80),
            maxDebounceInterval: .seconds(10)
        )
        await publisher.start()
        await publisher.start() // No throw, no duplicate work.
        defer { Task { await publisher.stop() } }

        publisher.scheduleDebouncedPublish()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(uploader.uploadCallCount, 1)
    }
}
