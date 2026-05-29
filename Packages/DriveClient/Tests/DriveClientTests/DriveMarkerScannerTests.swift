import XCTest
@testable import DriveClient
import DriveTestSupport

final class DriveMarkerScannerTests: XCTestCase {

    private func authorizedSession(for client: HTTPClient) -> AuthorizedSession {
        AuthorizedSession(client: client, provider: StubTokenProvider(accessTokens: ["t"]))
    }

    /// `{"files": [{"id": ..., "name": ...}]}` — used for the folder
    /// resolver's `/PhotoTool/` root lookup.
    private func folderList(_ files: [(id: String, name: String)]) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["files": files.map { ["id": $0.id, "name": $0.name] }],
            options: []
        )
    }

    /// One page of `listChildrenRequest` results.
    private func childPage(
        files: [[String: Any]],
        nextPageToken: String? = nil
    ) -> Data {
        var obj: [String: Any] = ["files": files]
        if let nextPageToken { obj["nextPageToken"] = nextPageToken }
        return try! JSONSerialization.data(withJSONObject: obj, options: [])
    }

    private func makeScanner(http: RoutingStubHTTPClient) -> DriveMarkerScanner {
        let session = authorizedSession(for: http)
        let resolver = DriveFolderResolver(
            session: session,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        return DriveMarkerScanner(
            session: session,
            folderResolver: resolver,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
    }

    /// Routes the `/PhotoTool/` root resolve plus a two-page child listing
    /// on the root, where page 1 includes a subfolder that holds the one
    /// untagged file. Exercises pagination *and* recursion.
    private func wireTree(_ http: RoutingStubHTTPClient) {
        // Resolve /PhotoTool/ → id-pt.
        http.route(
            method: "GET",
            urlContains: "PhotoTool",
            response: .init(status: 200, body: folderList([("id-pt", "PhotoTool")]))
        )
        // Root children, page 1 (tagged file + subfolder) then page 2
        // (another tagged file).
        http.route(
            method: "GET",
            urlContains: "id-pt",
            responses: [
                .init(status: 200, body: childPage(
                    files: [
                        ["id": "tagged-root", "name": "a.jpg", "mimeType": "image/jpeg",
                         "appProperties": ["dimroom": "1"]],
                        ["id": "sub-id", "name": "2024", "mimeType": DriveFilesAPI.folderMimeType],
                    ],
                    nextPageToken: "page-2"
                )),
                .init(status: 200, body: childPage(
                    files: [
                        ["id": "tagged-root-2", "name": "b.jpg", "mimeType": "image/jpeg",
                         "appProperties": ["dimroom": "1"]],
                    ]
                )),
            ]
        )
        // Subfolder children — the single untagged legacy file.
        http.route(
            method: "GET",
            urlContains: "sub-id",
            response: .init(status: 200, body: childPage(
                files: [
                    ["id": "untagged-deep", "name": "old.jpg", "mimeType": "image/jpeg"],
                ]
            ))
        )
    }

    func testWalksAllPagesAndRecursesIntoFolders() async throws {
        let http = RoutingStubHTTPClient()
        wireTree(http)
        let scanner = makeScanner(http: http)

        let files = try await scanner.listAllFiles()

        // All three non-folder files across both root pages and the
        // recursed subfolder; the folder entry itself is not returned.
        XCTAssertEqual(Set(files.map(\.id)), ["tagged-root", "tagged-root-2", "untagged-deep"])
    }

    func testBackfillPatchesExactlyTheUntaggedFile() async throws {
        let http = RoutingStubHTTPClient()
        wireTree(http)
        // PATCH for the lone untagged file.
        http.route(
            method: "PATCH",
            urlContains: "/files/untagged-deep",
            response: .init(status: 200, body: Data())
        )
        let scanner = makeScanner(http: http)
        let backfill = DriveMarkerBackfill(scanner: scanner, throttle: .zero)

        let summary = try await backfill.run()

        XCTAssertEqual(summary, BackfillSummary(scanned: 3, patched: 1, skipped: 2))
        // Exactly one PATCH issued, and only to the untagged file.
        let patches = http.requestsMatching(method: "PATCH", urlContains: "/files/")
        XCTAssertEqual(patches.count, 1)
        XCTAssertTrue(
            patches[0].url!.absoluteString.hasSuffix("/files/untagged-deep"),
            "got: \(patches[0].url!)"
        )
    }

    func testPatchMarkerSendsMergeBody() async throws {
        let http = RoutingStubHTTPClient()
        http.route(
            method: "PATCH",
            urlContains: "/files/file-9",
            response: .init(status: 200, body: Data())
        )
        let scanner = makeScanner(http: http)

        try await scanner.patchMarker(fileId: "file-9")

        let patches = http.requestsMatching(method: "PATCH", urlContains: "/files/file-9")
        XCTAssertEqual(patches.count, 1)
        let body = try XCTUnwrap(patches[0].body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["appProperties"] as? [String: String], ["dimroom": "1"])
    }
}
