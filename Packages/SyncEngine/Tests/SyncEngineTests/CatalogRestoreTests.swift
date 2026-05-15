import XCTest
@testable import SyncEngine

final class CatalogRestoreTests: XCTestCase {

    private func tempLocalPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-restore-\(UUID().uuidString)")
            .appendingPathComponent("catalog.sqlite")
            .path
    }

    private func cleanup(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: parent)
    }

    func testLocalFilePresentShortCircuits() async throws {
        let path = tempLocalPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(to: URL(fileURLWithPath: path))
        defer { cleanup(path) }

        let uploader = StubCatalogUploader(behavior: .alwaysFail(.uploadFailed(underlying: "should not be called")))
        let store = InMemoryDriveFileIdStore()

        let outcome = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: store,
            prompt: { _ in
                XCTFail("prompt should not be called when local file exists")
                return false
            }
        )
        XCTAssertEqual(outcome, .localCatalogPresent)
        XCTAssertEqual(uploader.findCalls, 0)
        XCTAssertEqual(uploader.downloadCalls.count, 0)
    }

    func testNoRemoteCatalogReturnsNoRemote() async throws {
        let path = tempLocalPath()
        defer { cleanup(path) }
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: true)
        ))
        // No remote catalog configured on the stub.

        let outcome = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            prompt: { _ in
                XCTFail("prompt should not fire when remote is absent")
                return false
            }
        )
        XCTAssertEqual(outcome, .noRemoteCatalog)
        XCTAssertEqual(uploader.findCalls, 1)
        XCTAssertEqual(uploader.downloadCalls.count, 0)
    }

    func testRemoteAcceptedDownloadsAndStoresFileId() async throws {
        let path = tempLocalPath()
        defer { cleanup(path) }
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: true)
        ))
        uploader.setRemoteCatalog(
            DriveCatalogRef(driveFileId: "remote-1", sizeBytes: 1234, modifiedTime: nil)
        )
        let payload = Data("catalog-bytes".utf8)
        uploader.setDownloadBytes(payload)
        uploader.setDownloadResult(.success(Int64(payload.count)))

        let store = InMemoryDriveFileIdStore()

        let outcome = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: store,
            prompt: { _ in true }
        )
        XCTAssertEqual(outcome, .restored(driveFileId: "remote-1", downloadedBytes: Int64(payload.count)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try store.load(), "remote-1")
    }

    func testRemoteDeclinedDoesNotDownload() async throws {
        let path = tempLocalPath()
        defer { cleanup(path) }
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: true)
        ))
        uploader.setRemoteCatalog(
            DriveCatalogRef(driveFileId: "remote-2", sizeBytes: 4096, modifiedTime: nil)
        )
        let store = InMemoryDriveFileIdStore()

        let outcome = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: store,
            prompt: { _ in false }
        )
        XCTAssertEqual(outcome, .declinedByUser)
        XCTAssertEqual(uploader.downloadCalls.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertNil(try store.load())
    }

    func testNotAuthenticatedSurfacedFromFindError() async throws {
        // A `notAuthenticated` from the uploader during the find should
        // be returned as a distinct outcome (not a thrown error) so the
        // restore path can degrade gracefully.
        let path = tempLocalPath()
        defer { cleanup(path) }
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: true)
        ))
        uploader.setFindError(.notAuthenticated)

        let outcome = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            prompt: { _ in true }
        )
        XCTAssertEqual(outcome, .notAuthenticated)
    }
}
