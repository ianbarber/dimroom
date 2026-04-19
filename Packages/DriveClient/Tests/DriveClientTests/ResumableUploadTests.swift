import XCTest
@testable import DriveClient

final class ResumableUploadTests: XCTestCase {

    func testBuildInitiateRequestShape() throws {
        let metadata = ResumableUpload.Metadata(
            name: "IMG.cr2",
            parents: ["fid"],
            mimeType: "image/x-canon-cr2",
            appProperties: ["contentHash": "h1"]
        )
        let req = try ResumableUpload.buildInitiateRequest(metadata: metadata)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(req.url!.absoluteString.contains("uploadType=resumable"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Upload-Content-Type"), "image/x-canon-cr2")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        XCTAssertEqual(json["name"] as? String, "IMG.cr2")
        XCTAssertEqual(json["parents"] as? [String], ["fid"])
        XCTAssertEqual((json["appProperties"] as? [String: String])?["contentHash"], "h1")
    }

    func testChunkRequestHeadersAndRange() {
        let url = URL(string: "https://upload.example/session?token=abc")!
        let req = ResumableUpload.buildChunkRequest(
            sessionURL: url,
            chunk: Data(repeating: 0xAA, count: 256 * 1024),
            rangeStart: 0,
            rangeEnd: 256 * 1024 - 1,
            total: 600_000,
            mimeType: "image/jpeg"
        )
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Range"), "bytes 0-262143/600000")
    }

    func testParseRangeAck() {
        XCTAssertEqual(ResumableUpload.parseRangeAck("bytes=0-524287"), 524287)
        XCTAssertEqual(ResumableUpload.parseRangeAck("bytes=0-0"), 0)
        XCTAssertNil(ResumableUpload.parseRangeAck(nil))
        XCTAssertNil(ResumableUpload.parseRangeAck("bytes 0-100"))
    }

    func testFullResumableUploadHappyPath() async throws {
        let bytes = [UInt8](repeating: 0x55, count: 300_000)
        let fixture = try writeFixture(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        let sessionURL = "https://upload.example/session-abc"
        // Initiate
        http.route(
            method: "POST",
            urlContains: "uploadType=resumable",
            response: .init(status: 200, body: Data(), headers: ["Location": sessionURL])
        )
        // Chunk PUTs — 300_000 bytes, chunk size 200_000. Two chunks:
        // 0-199_999 (200_000 bytes), 200_000-299_999 (100_000 bytes).
        // Server acks first, then returns 200 on final with file ID.
        http.route(
            method: "PUT",
            urlContains: "session-abc",
            responses: [
                .init(status: 308, headers: ["Range": "bytes=0-199999"]),
                .init(status: 200, body: Data(#"{"id":"f-final"}"#.utf8)),
            ]
        )

        let session = AuthorizedSession(
            client: http,
            provider: StubTokenProvider(accessTokens: ["t"])
        )

        var lastProgress: (Int64, Int64) = (0, 0)
        let id = try await ResumableUpload.upload(
            metadata: .init(name: "a.cr2", parents: ["f"], mimeType: "image/x-canon-cr2", appProperties: [:]),
            fileURL: fixture,
            totalBytes: Int64(bytes.count),
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero),
            clock: ContinuousClock(),
            chunkSize: 200_000,
            progress: { uploaded, total in lastProgress = (uploaded, total) }
        )
        XCTAssertEqual(id, "f-final")
        XCTAssertEqual(lastProgress.0, 300_000)
        XCTAssertEqual(lastProgress.1, 300_000)

        // Verify second PUT sent the final chunk 200_000-299_999.
        let puts = http.requestsMatching(method: "PUT", urlContains: "session-abc")
        XCTAssertEqual(puts.count, 2)
        XCTAssertEqual(puts[0].headers["Content-Range"], "bytes 0-199999/300000")
        XCTAssertEqual(puts[1].headers["Content-Range"], "bytes 200000-299999/300000")
    }

    func testResumableSessionLostOn410() async throws {
        let fixture = try writeFixture(bytes: Array(repeating: UInt8(1), count: 500))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        http.route(method: "POST", urlContains: "uploadType=resumable",
                   response: .init(status: 200, body: Data(),
                                   headers: ["Location": "https://upload.example/s"]))
        http.route(method: "PUT", urlContains: "upload.example/s",
                   response: .init(status: 410))

        let session = AuthorizedSession(client: http, provider: StubTokenProvider(accessTokens: ["t"]))
        do {
            _ = try await ResumableUpload.upload(
                metadata: .init(name: "a.jpg", parents: ["f"], mimeType: "image/jpeg", appProperties: [:]),
                fileURL: fixture,
                totalBytes: 500,
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero),
                clock: ContinuousClock(),
                chunkSize: 500,
                progress: { _, _ in }
            )
            XCTFail("expected failure")
        } catch DriveUploadError.resumableSessionLost {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - helpers

    private func writeFixture(bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.bin")
        try Data(bytes).write(to: url)
        return url
    }
}
