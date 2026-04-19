import XCTest
@testable import DriveClient

final class DownloadFileTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testIssuesAltMediaGetWithBearerToken() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let http = StubHTTPClient(responses: [
            // Access-token refresh.
            .success(200, Data(#"{"access_token":"tok-1","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
        ])
        let streaming = StubStreamingHTTPClient(responses: [
            .success(200, data: payload),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            streamingClient: streaming,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")

        try await client.downloadFile(id: "FILE-ID", to: dest)

        let written = try Data(contentsOf: dest)
        XCTAssertEqual(written, payload)
        XCTAssertEqual(streaming.captured.count, 1)
        let get = streaming.captured[0]
        XCTAssertEqual(get.method, "GET")
        XCTAssertEqual(
            get.url?.absoluteString,
            "https://www.googleapis.com/drive/v3/files/FILE-ID?alt=media"
        )
        XCTAssertEqual(get.headers["Authorization"], "Bearer tok-1")
    }

    func testHTTPErrorStatusThrowsDownloadFailed() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"tok-1","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
        ])
        let streaming = StubStreamingHTTPClient(responses: [
            .success(404, data: Data()),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            streamingClient: streaming,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")

        do {
            try await client.downloadFile(id: "MISSING", to: dest)
            XCTFail("expected downloadFailed")
        } catch DriveClientError.downloadFailed(let status) {
            XCTAssertEqual(status, 404)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testExpiredAccessTokenTriggersRefreshAndRetry() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            // Initial refresh to mint the first access token.
            .success(200, Data(#"{"access_token":"stale","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            // Refresh triggered by the 401 on the streaming leg.
            .success(200, Data(#"{"access_token":"fresh","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
        ])
        let streaming = StubStreamingHTTPClient(responses: [
            // First GET: 401 — Drive rejects the stale token.
            .success(401, data: Data()),
            // Retried GET: success.
            .success(200, data: Data("ok".utf8)),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            streamingClient: streaming,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")

        try await client.downloadFile(id: "FILE-ID", to: dest)

        let written = try Data(contentsOf: dest)
        XCTAssertEqual(String(data: written, encoding: .utf8), "ok")
        XCTAssertEqual(streaming.captured.count, 2)
        XCTAssertEqual(streaming.captured[0].headers["Authorization"], "Bearer stale")
        XCTAssertEqual(streaming.captured[1].headers["Authorization"], "Bearer fresh")

        // Partial from the 401 attempt must be cleaned up — nothing else in
        // the parent directory besides the final destination file.
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents, ["file.bin"])
    }

    func testProgressCallbackFiresOnCompletion() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"tok","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
        ])
        let streaming = StubStreamingHTTPClient(responses: [
            .success(200, data: Data(repeating: 0xAB, count: 1024)),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            streamingClient: streaming,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")
        let reported = Reported()

        try await client.downloadFile(id: "FILE", to: dest, progress: { value in
            reported.record(value)
        })

        let values = reported.values
        XCTAssertEqual(values.last, 1.0)
    }

    func testStreamsChunkedPayloadFiresProgressMultipleTimes() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"tok","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
        ])
        let chunks = [
            Data(repeating: 0x01, count: 256),
            Data(repeating: 0x02, count: 256),
            Data(repeating: 0x03, count: 256),
            Data(repeating: 0x04, count: 256),
        ]
        let streaming = StubStreamingHTTPClient(responses: [
            .success(200, chunks: chunks),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            streamingClient: streaming,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")
        let reported = Reported()

        try await client.downloadFile(id: "FILE", to: dest, progress: { value in
            reported.record(value)
        })

        let values = reported.values
        XCTAssertGreaterThanOrEqual(values.count, 4)
        XCTAssertEqual(values.last, 1.0)
        for (previous, current) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThanOrEqual(current, previous)
        }
        let written = try Data(contentsOf: dest)
        XCTAssertEqual(written, chunks.reduce(Data(), +))
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func record(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            storage.append(value)
        }
        var values: [Double] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }
}
