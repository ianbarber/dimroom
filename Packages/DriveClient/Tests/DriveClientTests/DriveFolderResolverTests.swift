import XCTest
@testable import DriveClient

final class DriveFolderResolverTests: XCTestCase {

    private func stubFolderList(files: [(id: String, name: String)]) -> Data {
        let filesJSON = files.map { ["id": $0.id, "name": $0.name] }
        return try! JSONSerialization.data(
            withJSONObject: ["files": filesJSON],
            options: []
        )
    }

    private func stubFolder(id: String, name: String) -> Data {
        try! JSONSerialization.data(
            withJSONObject: ["id": id, "name": name],
            options: []
        )
    }

    private func authorizedSession(for client: HTTPClient) -> AuthorizedSession {
        AuthorizedSession(client: client, provider: StubTokenProvider(accessTokens: ["t"]))
    }

    func testResolvesExistingChain() async throws {
        let http = RoutingStubHTTPClient()
        // All three segments already exist.
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: stubFolderList(files: [("id-pt", "PhotoTool")])))
        http.route(method: "GET", urlContains: "'library'",
                   response: .init(status: 200, body: stubFolderList(files: [("id-lib", "library")])))
        http.route(method: "GET", urlContains: "'2024'",
                   response: .init(status: 200, body: stubFolderList(files: [("id-2024", "2024")])))

        let resolver = DriveFolderResolver(
            session: authorizedSession(for: http),
            root: .folderId("root-id"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let id = try await resolver.resolve(segments: ["PhotoTool", "library", "2024"])
        XCTAssertEqual(id, "id-2024")
    }

    func testCreatesMissingSegment() async throws {
        let http = RoutingStubHTTPClient()
        // PhotoTool exists; library is missing and needs to be created.
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: stubFolderList(files: [("id-pt", "PhotoTool")])))
        http.route(method: "GET", urlContains: "'library'",
                   response: .init(status: 200, body: stubFolderList(files: [])))
        http.route(method: "POST", urlContains: "https://www.googleapis.com/drive/v3/files",
                   response: .init(status: 200, body: stubFolder(id: "new-lib", name: "library")))

        let resolver = DriveFolderResolver(
            session: authorizedSession(for: http),
            root: .folderId("root-id"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let id = try await resolver.resolve(segments: ["PhotoTool", "library"])
        XCTAssertEqual(id, "new-lib")

        // One POST should have landed for the create.
        let creates = http.requestsMatching(
            method: "POST",
            urlContains: "https://www.googleapis.com/drive/v3/files"
        )
        XCTAssertEqual(creates.count, 1)
    }

    func testMemoisesFolderIDs() async throws {
        let http = RoutingStubHTTPClient()
        // One list answer for "daily"; if the resolver asks twice, the
        // second call will find no responses and throw.
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: stubFolderList(files: [("id-pt", "PhotoTool")])))
        http.route(method: "GET", urlContains: "'daily'",
                   response: .init(status: 200, body: stubFolderList(files: [("id-daily", "daily")])))

        let resolver = DriveFolderResolver(
            session: authorizedSession(for: http),
            root: .folderId("root-id"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        _ = try await resolver.resolve(segments: ["PhotoTool", "daily"])
        // Second call — must NOT hit the network.
        _ = try await resolver.resolve(segments: ["PhotoTool", "daily"])

        XCTAssertEqual(
            http.requestsMatching(method: "GET", urlContains: "'daily'").count,
            1
        )
    }

    func testPicksFirstWhenMultipleListed() async throws {
        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(
                    status: 200,
                    body: stubFolderList(files: [("a", "PhotoTool"), ("b", "PhotoTool")])
                   ))

        let resolver = DriveFolderResolver(
            session: authorizedSession(for: http),
            root: .folderId("root-id"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        let id = try await resolver.resolve(segments: ["PhotoTool"])
        XCTAssertEqual(id, "a")
    }

    func testFolderCreationFailureSurfaces() async {
        let http = RoutingStubHTTPClient()
        http.route(method: "GET", urlContains: "'PhotoTool'",
                   response: .init(status: 200, body: stubFolderList(files: [])))
        http.route(method: "POST", urlContains: "https://www.googleapis.com/drive/v3/files",
                   response: .init(status: 400, body: Data()))

        let resolver = DriveFolderResolver(
            session: authorizedSession(for: http),
            root: .folderId("root-id"),
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)
        )
        do {
            _ = try await resolver.resolve(segments: ["PhotoTool"])
            XCTFail("expected failure")
        } catch let DriveUploadError.folderCreationFailed(status) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
