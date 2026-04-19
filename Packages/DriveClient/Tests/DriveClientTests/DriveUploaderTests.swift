import XCTest
@testable import DriveClient

final class DriveUploaderTests: XCTestCase {

    private func stubFolderList(_ files: [(id: String, name: String)]) -> Data {
        let filesJSON = files.map { ["id": $0.id, "name": $0.name] }
        return try! JSONSerialization.data(
            withJSONObject: ["files": filesJSON],
            options: []
        )
    }

    private func writeFixture(bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func sampleRef(localPath: URL, bytes: Int64 = 100) -> DriveAssetRef {
        DriveAssetRef(
            assetId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            localPath: localPath,
            contentHash: "hash-abc",
            originalFilename: "IMG.jpg",
            bytes: bytes,
            captureDate: ISO8601DateFormatter().date(from: "2024-06-14T12:00:00Z"),
            importedDate: ISO8601DateFormatter().date(from: "2024-06-14T15:00:00Z")!,
            sourceType: .digital,
            mimeType: "image/jpeg"
        )
    }

    private func authorizedSession(for client: HTTPClient) -> AuthorizedSession {
        AuthorizedSession(client: client, provider: StubTokenProvider(accessTokens: ["t"]))
    }

    func testDedupShortCircuitsUpload() async throws {
        let fixture = try writeFixture(bytes: [1, 2, 3])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        // Folder chain — all 5 segments already present.
        let segments = ["PhotoTool", "library", "2024", "2024-06-14", "digital"]
        for (i, segment) in segments.enumerated() {
            http.route(
                method: "GET",
                urlContains: "'\(segment)'",
                response: .init(
                    status: 200,
                    body: stubFolderList([("id-\(i)", segment)])
                )
            )
        }
        // Dedup lookup → hit.
        http.route(
            method: "GET",
            urlContains: "contentHash",
            response: .init(
                status: 200,
                body: stubFolderList([("existing-file-id", "existing")])
            )
        )

        let session = authorizedSession(for: http)
        let resolver = DriveFolderResolver(
            session: session,
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveUploader(
            session: session,
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let outcome = try await uploader.upload(sampleRef(localPath: fixture)) { _, _ in }
        XCTAssertEqual(outcome, .skippedDuplicate(fileID: "existing-file-id"))

        // Crucially: no upload request was issued.
        let uploads = http.requestsMatching(method: "POST", urlContains: "/upload/drive/v3/files")
        XCTAssertTrue(uploads.isEmpty, "dedup hit must not trigger an upload")
    }

    func testSimpleUploadHappyPath() async throws {
        let fixture = try writeFixture(bytes: Array(repeating: UInt8(7), count: 100))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        let segments = ["PhotoTool", "library", "2024", "2024-06-14", "digital"]
        for (i, segment) in segments.enumerated() {
            http.route(method: "GET", urlContains: "'\(segment)'",
                       response: .init(status: 200, body: stubFolderList([("id-\(i)", segment)])))
        }
        // No dedup hit.
        http.route(method: "GET", urlContains: "contentHash",
                   response: .init(status: 200, body: stubFolderList([])))
        // Multipart upload.
        http.route(method: "POST", urlContains: "uploadType=multipart",
                   response: .init(status: 200, body: Data(#"{"id":"uploaded-xyz"}"#.utf8)))

        let session = authorizedSession(for: http)
        let resolver = DriveFolderResolver(
            session: session,
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveUploader(
            session: session,
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero),
            simpleUploadThreshold: 5 * 1024 * 1024
        )
        let outcome = try await uploader.upload(sampleRef(localPath: fixture, bytes: 100)) { _, _ in }
        XCTAssertEqual(outcome, .uploaded(fileID: "uploaded-xyz"))
    }

    func testResumableUploadTriggeredByLargeFile() async throws {
        // 500 bytes of content, but we set the threshold to 100 so the
        // uploader picks resumable.
        let fixture = try writeFixture(bytes: Array(repeating: UInt8(3), count: 500))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        let segments = ["PhotoTool", "library", "2024", "2024-06-14", "digital"]
        for (i, segment) in segments.enumerated() {
            http.route(method: "GET", urlContains: "'\(segment)'",
                       response: .init(status: 200, body: stubFolderList([("id-\(i)", segment)])))
        }
        http.route(method: "GET", urlContains: "contentHash",
                   response: .init(status: 200, body: stubFolderList([])))
        http.route(method: "POST", urlContains: "uploadType=resumable",
                   response: .init(
                    status: 200,
                    body: Data(),
                    headers: ["Location": "https://upload.example/s-resumable"]
                   ))
        http.route(method: "PUT", urlContains: "s-resumable",
                   response: .init(status: 200, body: Data(#"{"id":"resumable-id"}"#.utf8)))

        let session = authorizedSession(for: http)
        let resolver = DriveFolderResolver(
            session: session,
            root: .folderId("root"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let uploader = DriveUploader(
            session: session,
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero),
            simpleUploadThreshold: 100,
            resumableChunkSize: 500
        )
        let outcome = try await uploader.upload(sampleRef(localPath: fixture, bytes: 500)) { _, _ in }
        XCTAssertEqual(outcome, .uploaded(fileID: "resumable-id"))
    }

    func testMissingLocalFileThrows() async {
        let missing = URL(fileURLWithPath: "/var/folders/definitely-not-there-\(UUID().uuidString)")
        let http = RoutingStubHTTPClient()
        let session = authorizedSession(for: http)
        let resolver = DriveFolderResolver(session: session, root: .folderId("root"))
        let uploader = DriveUploader(session: session, folderResolver: resolver)
        do {
            _ = try await uploader.upload(sampleRef(localPath: missing)) { _, _ in }
            XCTFail("expected failure")
        } catch let DriveUploadError.missingLocalFile(id) {
            XCTAssertEqual(id.uuidString, "11111111-2222-3333-4444-555555555555")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
