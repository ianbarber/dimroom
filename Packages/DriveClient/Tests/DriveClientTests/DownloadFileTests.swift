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
            // First call: access-token refresh.
            .success(200, Data(#"{"access_token":"tok-1","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            // Second call: the media download itself.
            .success(200, payload),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")

        try await client.downloadFile(id: "FILE-ID", to: dest)

        let written = try Data(contentsOf: dest)
        XCTAssertEqual(written, payload)
        XCTAssertEqual(http.captured.count, 2)
        let get = http.captured[1]
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
            .success(404, Data()),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
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
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testExpiredAccessTokenTriggersRefreshAndRetry() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            // Initial refresh to get the first access token.
            .success(200, Data(#"{"access_token":"stale","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            // First GET: 401 — Drive says the token is no good anymore.
            .success(401, Data()),
            // Refresh in response to the 401.
            .success(200, Data(#"{"access_token":"fresh","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            // Retried GET: success.
            .success(200, Data("ok".utf8)),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")

        try await client.downloadFile(id: "FILE-ID", to: dest)

        let written = try Data(contentsOf: dest)
        XCTAssertEqual(String(data: written, encoding: .utf8), "ok")
        XCTAssertEqual(http.captured.count, 4)
        XCTAssertEqual(http.captured[1].headers["Authorization"], "Bearer stale")
        XCTAssertEqual(http.captured[3].headers["Authorization"], "Bearer fresh")
    }

    func testProgressCallbackFiresOnCompletion() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"tok","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            .success(200, Data(repeating: 0xAB, count: 1024)),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
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

    func testProgressFiresForMultipleChunks() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let payload = Data(repeating: 0xCD, count: 1024)
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"tok","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            .success(200, payload),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
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
        XCTAssertGreaterThanOrEqual(values.count, 4, "expected per-chunk progress, got \(values)")
        for index in 1..<values.count {
            XCTAssertGreaterThanOrEqual(
                values[index],
                values[index - 1],
                "progress went backwards at index \(index): \(values)"
            )
        }
        XCTAssertEqual(values.last, 1.0)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testPartFileCleanedUpOnFailure() async throws {
        let tokens = InMemoryTokenStore(initial: "refresh-1")
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"tok","expires_in":3600,"token_type":"Bearer"}"#.utf8)),
            .success(404, Data()),
        ])
        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            tokenStore: tokens
        )
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dest = tempDir.appendingPathComponent("file.bin")

        do {
            try await client.downloadFile(id: "MISSING", to: dest)
            XCTFail("expected downloadFailed")
        } catch DriveClientError.downloadFailed {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dest.appendingPathExtension("part").path)
        )
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
