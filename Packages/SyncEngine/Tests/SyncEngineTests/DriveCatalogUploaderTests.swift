import XCTest
import DriveClient
@testable import SyncEngine

final class DriveCatalogUploaderTests: XCTestCase {

    private func writeSnapshotFile(_ bytes: Data = Data("sqlite-bytes".utf8)) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-snapshot-\(UUID().uuidString).sqlite")
        try bytes.write(to: url)
        return url.path
    }

    private func uploadResponseBody(id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id])
    }

    private func folderListBody(id: String, name: String) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["files": [["id": id, "name": name]]]
        )
    }

    private func emptyFolderListBody() -> Data {
        try! JSONSerialization.data(withJSONObject: ["files": []])
    }

    private func folderCreateBody(id: String, name: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "name": name])
    }

    private func sessionWith(client: HTTPClient) -> AuthorizedSession {
        AuthorizedSession(client: client, provider: StubTokenProvider(accessTokens: ["t"]))
    }

    private func sessionWith(client: HTTPClient, streaming: StreamingHTTPClient) -> AuthorizedSession {
        AuthorizedSession(
            client: client,
            streamingClient: streaming,
            provider: StubTokenProvider(accessTokens: ["t"])
        )
    }

    // MARK: - Upload: create

    func testUploadCreatesNewCatalogWhenNoExistingFileId() async throws {
        let snapshotPath = try writeSnapshotFile()
        defer { try? FileManager.default.removeItem(atPath: snapshotPath) }

        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: folderListBody(id: "id-photo", name: "PhotoTool")))
        http.route(method: "GET", urlContains: "'catalog'",
                   response: .init(status: 200, body: folderListBody(id: "id-cat", name: "catalog")))
        http.route(method: "POST", urlContains: "/upload/drive/v3/files",
                   response: .init(status: 200, body: uploadResponseBody(id: "drive-new-1")))

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        let result = try await uploader.upload(
            snapshotPath: snapshotPath,
            existingFileId: nil,
            photoCount: 42
        )
        XCTAssertEqual(result.driveFileId, "drive-new-1")
        XCTAssertTrue(result.wasCreate)
        XCTAssertGreaterThan(result.uploadedBytes, 0)

        let posts = http.requestsMatching(method: "POST", urlContains: "/upload/drive/v3/files")
        XCTAssertEqual(posts.count, 1)
        let post = posts[0]
        XCTAssertEqual(post.url?.query?.contains("uploadType=multipart"), true)
        XCTAssertEqual(post.url?.query?.contains("fields=id"), true)
        XCTAssertTrue(post.headers["Content-Type"]?.contains("multipart/related") ?? false)
        // The metadata part should contain the catalog folder id and
        // the canonical filename.
        let body = String(data: post.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"name\":\"catalog.sqlite\""), body)
        XCTAssertTrue(body.contains("\"parents\":[\"id-cat\"]"), body)
        XCTAssertTrue(body.contains("application/x-sqlite3"), body)
        // appProperties stamped on create so a fresh machine's restore
        // prompt can read the photo count back without downloading.
        XCTAssertTrue(
            body.contains("\"appProperties\""),
            "expected appProperties in metadata: \(body)"
        )
        XCTAssertTrue(
            body.contains("\"dimroom_photo_count\":\"42\""),
            "expected dimroom_photo_count='42' (string-typed appProperty): \(body)"
        )
    }

    // MARK: - Upload: update

    func testUploadPatchesExistingFileId() async throws {
        let snapshotPath = try writeSnapshotFile()
        defer { try? FileManager.default.removeItem(atPath: snapshotPath) }

        let http = RoutingStubHTTPClient()
        http.route(method: "PATCH", urlContains: "/upload/drive/v3/files/drive-existing",
                   response: .init(status: 200, body: uploadResponseBody(id: "drive-existing")))

        // Folder resolver should not be called on the update path —
        // wire it but assert no folder lookups occurred.
        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        let result = try await uploader.upload(
            snapshotPath: snapshotPath,
            existingFileId: "drive-existing",
            photoCount: 17
        )
        XCTAssertEqual(result.driveFileId, "drive-existing")
        XCTAssertFalse(result.wasCreate)

        let patches = http.requestsMatching(method: "PATCH", urlContains: "/drive-existing")
        XCTAssertEqual(patches.count, 1)
        let folderLookups = http.requestsMatching(method: "GET", urlContains: "drive/v3/files?")
        XCTAssertEqual(folderLookups.count, 0, "update path must skip folder resolution")

        // PATCH body must not re-send `parents` (Drive rejects).
        let body = String(data: patches[0].body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("\"parents\""), "PATCH body must not include parents: \(body)")
        XCTAssertTrue(body.contains("application/x-sqlite3"), body)
        XCTAssertTrue(
            body.contains("\"dimroom_photo_count\":\"17\""),
            "PATCH must refresh photo count: \(body)"
        )
    }

    // MARK: - Errors

    func testUploadServerErrorMapsToUploadFailed() async throws {
        let snapshotPath = try writeSnapshotFile()
        defer { try? FileManager.default.removeItem(atPath: snapshotPath) }

        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: folderListBody(id: "id-photo", name: "PhotoTool")))
        http.route(method: "GET", urlContains: "'catalog'",
                   response: .init(status: 200, body: folderListBody(id: "id-cat", name: "catalog")))
        http.route(method: "POST", urlContains: "/upload/drive/v3/files",
                   response: .init(status: 500, body: Data("server boom".utf8)))

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        do {
            _ = try await uploader.upload(
                snapshotPath: snapshotPath,
                existingFileId: nil,
                photoCount: nil
            )
            XCTFail("expected upload error")
        } catch let error as SyncEngineError {
            guard case .uploadFailed = error else {
                XCTFail("expected uploadFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - findExistingCatalog

    func testFindExistingCatalogParsesResponse() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "files": [[
                "id": "remote-cat",
                "name": "catalog.sqlite",
                "modifiedTime": "2025-01-01T12:00:00Z",
                "size": "4096",
                "appProperties": ["dimroom_photo_count": "27"],
            ]],
        ])

        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: folderListBody(id: "id-photo", name: "PhotoTool")))
        http.route(method: "GET", urlContains: "'catalog'",
                   response: .init(status: 200, body: folderListBody(id: "id-cat", name: "catalog")))
        http.route(method: "GET", urlContains: "name%20%3D%20'catalog.sqlite'",
                   response: .init(status: 200, body: body))

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        let ref = try await uploader.findExistingCatalog()
        XCTAssertEqual(ref?.driveFileId, "remote-cat")
        XCTAssertEqual(ref?.sizeBytes, 4096)
        XCTAssertNotNil(ref?.modifiedTime)
        XCTAssertEqual(ref?.photoCount, 27, "photoCount must come from appProperties")
    }

    func testFindExistingCatalogTreatsMissingAppPropertiesAsNilPhotoCount() async throws {
        // Legacy catalogs published before #234 lack `appProperties`.
        // Parser must surface photoCount=nil rather than 0 so the UI
        // can drop the count fragment from the prompt body.
        let body = try JSONSerialization.data(withJSONObject: [
            "files": [[
                "id": "legacy-cat",
                "name": "catalog.sqlite",
                "modifiedTime": "2025-01-01T12:00:00Z",
                "size": "4096",
            ]],
        ])
        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: folderListBody(id: "id-photo", name: "PhotoTool")))
        http.route(method: "GET", urlContains: "'catalog'",
                   response: .init(status: 200, body: folderListBody(id: "id-cat", name: "catalog")))
        http.route(method: "GET", urlContains: "name%20%3D%20'catalog.sqlite'",
                   response: .init(status: 200, body: body))

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        let ref = try await uploader.findExistingCatalog()
        XCTAssertEqual(ref?.driveFileId, "legacy-cat")
        XCTAssertNil(ref?.photoCount)
    }

    func testFindExistingCatalogReturnsNilWhenAbsent() async throws {
        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: folderListBody(id: "id-photo", name: "PhotoTool")))
        http.route(method: "GET", urlContains: "'catalog'",
                   response: .init(status: 200, body: folderListBody(id: "id-cat", name: "catalog")))
        http.route(method: "GET", urlContains: "name%20%3D%20'catalog.sqlite'",
                   response: .init(status: 200, body: emptyFolderListBody()))

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        let ref = try await uploader.findExistingCatalog()
        XCTAssertNil(ref)
    }

    // MARK: - Download

    func testDownloadWritesFileAndReturnsByteCount() async throws {
        let downloadDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-download-\(UUID().uuidString)")
            .appendingPathComponent("catalog.sqlite")
        defer {
            try? FileManager.default.removeItem(
                at: downloadDest.deletingLastPathComponent()
            )
        }

        let payload = Data("downloaded-catalog-bytes".utf8)
        let http = StubHTTPClient(responses: [])
        let streaming = StubStreamingHTTPClient(status: 200, body: payload)

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http, streaming: streaming),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        let bytes = try await uploader.download(fileId: "abc-123", to: downloadDest.path)
        XCTAssertEqual(bytes, Int64(payload.count))
        XCTAssertEqual(
            try Data(contentsOf: downloadDest),
            payload
        )
        // Confirm the request URL used alt=media against the right id.
        XCTAssertEqual(streaming.captured.count, 1)
        let urlString = streaming.captured[0].url?.absoluteString ?? ""
        XCTAssertTrue(urlString.contains("/drive/v3/files/abc-123"))
        XCTAssertTrue(urlString.contains("alt=media"))
    }

    func testDownloadServerErrorMapsToRestoreFailed() async throws {
        let downloadDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-download-\(UUID().uuidString)")
            .appendingPathComponent("catalog.sqlite")
        defer {
            try? FileManager.default.removeItem(
                at: downloadDest.deletingLastPathComponent()
            )
        }

        let http = StubHTTPClient(responses: [])
        let streaming = StubStreamingHTTPClient(status: 500, body: Data())

        let resolver = DriveFolderResolver(
            session: sessionWith(client: http),
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveCatalogUploader(
            session: sessionWith(client: http, streaming: streaming),
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )

        do {
            _ = try await uploader.download(fileId: "abc", to: downloadDest.path)
            XCTFail("expected download error")
        } catch let error as SyncEngineError {
            guard case .restoreFailed = error else {
                XCTFail("expected restoreFailed, got \(error)")
                return
            }
        }
    }
}
