import XCTest
@testable import DriveClient
import DriveTestSupport

final class SimpleUploadTests: XCTestCase {

    func testBuildRequestShapeIsMultipartRelated() throws {
        let metadata = SimpleUpload.Metadata(
            name: "IMG_0001.cr2",
            parents: ["folder-abc"],
            mimeType: "image/x-canon-cr2",
            appProperties: ["contentHash": "hash-xyz", "dimroomAssetId": "asset-uuid"]
        )
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let boundary = "BOUND-TEST"
        let req = try SimpleUpload.buildRequest(metadata: metadata, fileData: data, boundary: boundary)

        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertTrue(req.url!.absoluteString.contains("uploadType=multipart"))
        XCTAssertTrue(req.url!.absoluteString.contains("fields=id"))
        XCTAssertEqual(
            req.value(forHTTPHeaderField: "Content-Type"),
            "multipart/related; boundary=BOUND-TEST"
        )
        let body = String(data: req.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("--BOUND-TEST\r\n"))
        XCTAssertTrue(body.contains("Content-Type: application/json"))
        XCTAssertTrue(body.contains("Content-Type: image/x-canon-cr2"))
        XCTAssertTrue(body.contains("\"contentHash\":\"hash-xyz\""))
        XCTAssertTrue(body.contains("\"dimroomAssetId\":\"asset-uuid\""))
        XCTAssertTrue(body.contains("\"name\":\"IMG_0001.cr2\""))
        XCTAssertTrue(body.contains("--BOUND-TEST--"))
    }

    func testUploadReturnsFileIDOnSuccess() async throws {
        let fixture = try writeFixture(bytes: [0xAA, 0xBB, 0xCC])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        http.route(method: "POST", urlContains: "uploadType=multipart",
                   response: .init(status: 200, body: Data(#"{"id":"file-123"}"#.utf8)))
        let session = AuthorizedSession(client: http, provider: StubTokenProvider(accessTokens: ["t"]))

        var progressCalls: [(Int64, Int64)] = []
        let id = try await SimpleUpload.upload(
            metadata: .init(
                name: "a.jpg",
                parents: ["f"],
                mimeType: "image/jpeg",
                appProperties: ["contentHash": "h"]
            ),
            fileURL: fixture,
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero),
            clock: ContinuousClock(),
            boundary: "B",
            progress: { uploaded, total in
                progressCalls.append((uploaded, total))
            }
        )
        XCTAssertEqual(id, "file-123")
        XCTAssertEqual(progressCalls.count, 1)
        XCTAssertEqual(progressCalls[0].0, 3)
        XCTAssertEqual(progressCalls[0].1, 3)
    }

    func testUploadRetriesOn5xxThenSucceeds() async throws {
        let fixture = try writeFixture(bytes: [1, 2, 3])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        http.route(
            method: "POST",
            urlContains: "uploadType=multipart",
            responses: [
                .init(status: 500),
                .init(status: 200, body: Data(#"{"id":"f-ok"}"#.utf8)),
            ]
        )
        let session = AuthorizedSession(client: http, provider: StubTokenProvider(accessTokens: ["t"]))

        let id = try await SimpleUpload.upload(
            metadata: .init(name: "a.jpg", parents: ["f"], mimeType: "image/jpeg", appProperties: [:]),
            fileURL: fixture,
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .zero, maxDelay: .zero),
            clock: ContinuousClock(),
            progress: { _, _ in }
        )
        XCTAssertEqual(id, "f-ok")
        XCTAssertEqual(http.captured.count, 2)
    }

    func testUploadSurfaces4xx() async throws {
        let fixture = try writeFixture(bytes: [1])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let http = RoutingStubHTTPClient()
        http.route(method: "POST", urlContains: "uploadType=multipart",
                   response: .init(status: 400, body: Data("nope".utf8)))
        let session = AuthorizedSession(client: http, provider: StubTokenProvider(accessTokens: ["t"]))

        do {
            _ = try await SimpleUpload.upload(
                metadata: .init(name: "a.jpg", parents: ["f"], mimeType: "image/jpeg", appProperties: [:]),
                fileURL: fixture,
                session: session,
                retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .zero, maxDelay: .zero),
                clock: ContinuousClock(),
                progress: { _, _ in }
            )
            XCTFail("expected failure")
        } catch let DriveUploadError.uploadFailed(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, "nope")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // 4xx is fatal — should not have retried.
        XCTAssertEqual(http.captured.count, 1)
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
