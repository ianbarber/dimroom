import XCTest
@testable import SyncEngine

/// Captures the `CatalogRestorePrompt` argument from an async closure
/// so a test can assert on its fields after `restoreIfNeeded` returns.
private final class PromptCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: CatalogRestorePrompt?
    var value: CatalogRestorePrompt? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ v: CatalogRestorePrompt) {
        lock.lock(); _value = v; lock.unlock()
    }
}

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
            DriveCatalogRef(
                driveFileId: "remote-1",
                sizeBytes: 1234,
                modifiedTime: nil,
                photoCount: 7
            )
        )
        let payload = Data("catalog-bytes".utf8)
        uploader.setDownloadBytes(payload)
        uploader.setDownloadResult(.success(Int64(payload.count)))

        let store = InMemoryDriveFileIdStore()

        // Capture the prompt argument so we can assert photoCount
        // propagated end-to-end from DriveCatalogRef → CatalogRestorePrompt.
        let promptBox = PromptCaptureBox()
        let outcome = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: store,
            prompt: { prompt in
                promptBox.set(prompt)
                return true
            }
        )
        XCTAssertEqual(outcome, .restored(driveFileId: "remote-1", downloadedBytes: Int64(payload.count)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try store.load(), "remote-1")
        XCTAssertEqual(promptBox.value?.photoCount, 7)
        XCTAssertEqual(promptBox.value?.driveFileId, "remote-1")
        XCTAssertEqual(promptBox.value?.sizeBytes, 1234)
    }

    func testPromptPhotoCountNilForLegacyCatalogs() async throws {
        // Legacy catalogs published before #234 don't carry the
        // `appProperties.dimroom_photo_count` key. The DriveCatalogRef
        // surfaces photoCount=nil and the prompt must propagate that
        // instead of substituting a placeholder.
        let path = tempLocalPath()
        defer { cleanup(path) }
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: true)
        ))
        uploader.setRemoteCatalog(
            DriveCatalogRef(
                driveFileId: "legacy",
                sizeBytes: 4096,
                modifiedTime: nil,
                photoCount: nil
            )
        )
        uploader.setDownloadBytes(Data("legacy-bytes".utf8))
        uploader.setDownloadResult(.success(12))

        let promptBox = PromptCaptureBox()
        _ = try await CatalogPublisher.restoreIfNeeded(
            localPath: path,
            uploader: uploader,
            fileIdStore: InMemoryDriveFileIdStore(),
            prompt: { prompt in
                promptBox.set(prompt)
                return true
            }
        )
        XCTAssertNotNil(promptBox.value)
        XCTAssertNil(promptBox.value?.photoCount)
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

    func testRestoreFromLocalFileStubUploaderRoundTrip() async throws {
        // Round-trip a fixture catalog through `LocalFileStubCatalogUploader`.
        // Asserts size, photoCount (from sidecar JSON), and the file
        // content match what the harness flow expects.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let remotePath = work.appendingPathComponent("remote.sqlite")
        let payload = Data(repeating: 0x42, count: 256)
        try payload.write(to: remotePath)

        // Sidecar with the photo count — harness writes this so the
        // stub uploader can answer the count without opening SQLite.
        let sidecar = remotePath.appendingPathExtension("json")
        try Data(#"{"photoCount":11}"#.utf8).write(to: sidecar)

        let uploader = LocalFileStubCatalogUploader(sourcePath: remotePath.path)
        let ref = try await uploader.findExistingCatalog()
        XCTAssertEqual(ref?.sizeBytes, 256)
        XCTAssertEqual(ref?.photoCount, 11)

        let localPath = work.appendingPathComponent("restored.sqlite").path
        let bytes = try await uploader.download(fileId: ref!.driveFileId, to: localPath)
        XCTAssertEqual(bytes, 256)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: localPath)), payload)
    }

    func testLocalFileStubUploaderUsesInjectedPhotoCountOverSidecar() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let remotePath = work.appendingPathComponent("remote.sqlite")
        try Data("x".utf8).write(to: remotePath)
        // Sidecar present with a *different* count — the explicit init
        // arg should win so harness env vars can override.
        try Data(#"{"photoCount":1}"#.utf8).write(
            to: remotePath.appendingPathExtension("json")
        )
        let uploader = LocalFileStubCatalogUploader(
            sourcePath: remotePath.path,
            photoCount: 99
        )
        let ref = try await uploader.findExistingCatalog()
        XCTAssertEqual(ref?.photoCount, 99)
    }

    func testLocalFileStubUploaderReturnsNilWhenSourceAbsent() async throws {
        let uploader = LocalFileStubCatalogUploader(
            sourcePath: "/dev/null/no-such-file"
        )
        let ref = try await uploader.findExistingCatalog()
        XCTAssertNil(ref)
    }

    func testDownloadFailureSurfacesAsRestoreFailed() async throws {
        // The harness flow exercises this same wrapping end-to-end by
        // pointing the restore at a read-only local directory so
        // `LocalFileStubCatalogUploader.download` returns EACCES. This
        // Layer A test pins the wrapping logic without filesystem mode
        // games: `findExistingCatalog` succeeds, `download` throws, and
        // `restoreIfNeeded` must rethrow as `SyncEngineError.restoreFailed`.
        let path = tempLocalPath()
        defer { cleanup(path) }
        let uploader = StubCatalogUploader(behavior: .alwaysSucceed(
            CatalogUploadResult(driveFileId: "x", uploadedBytes: 0, wasCreate: true)
        ))
        uploader.setRemoteCatalog(
            DriveCatalogRef(
                driveFileId: "remote-fail",
                sizeBytes: 16,
                modifiedTime: nil,
                photoCount: 2
            )
        )
        uploader.setDownloadResult(.failure(.restoreFailed(underlying: "disk full")))

        do {
            _ = try await CatalogPublisher.restoreIfNeeded(
                localPath: path,
                uploader: uploader,
                fileIdStore: InMemoryDriveFileIdStore(),
                prompt: { _ in true }
            )
            XCTFail("expected restoreIfNeeded to throw on download failure")
        } catch let SyncEngineError.restoreFailed(underlying) {
            // Restore wraps the original error in `restoreFailed` —
            // assert the underlying description is preserved so the
            // harness payload's `error` field carries diagnostic detail.
            XCTAssertTrue(
                underlying.contains("restoreFailed") || underlying.contains("disk full"),
                "expected wrapped error to mention underlying cause; got: \(underlying)"
            )
        } catch {
            XCTFail("expected SyncEngineError.restoreFailed, got \(error)")
        }
        XCTAssertEqual(uploader.downloadCalls.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
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
