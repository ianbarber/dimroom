import XCTest
@testable import DriveClient
import DriveTestSupport

final class AuthorizedSessionTests: XCTestCase {
    func testSuccessPassesThrough() async throws {
        let http = StubHTTPClient(response: .success(200, Data("ok".utf8)))
        let provider = StubTokenProvider(accessTokens: ["a1"])
        let session = AuthorizedSession(client: http, provider: provider)

        let request = URLRequest(url: URL(string: "https://example/f")!)
        let (data, response) = try await session.data(for: request)

        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(http.captured.first?.headers["Authorization"], "Bearer a1")
        XCTAssertEqual(provider.currentCalls, 1)
        XCTAssertEqual(provider.refreshCalls, 0)
    }

    func testFirstCall401TriggersRefreshAndRetry() async throws {
        let http = StubHTTPClient(responses: [
            .success(401, Data("expired".utf8)),
            .success(200, Data("fresh".utf8)),
        ])
        let provider = StubTokenProvider(accessTokens: ["old", "new"])
        let session = AuthorizedSession(client: http, provider: provider)

        let (data, response) = try await session.data(for: URLRequest(url: URL(string: "https://example/f")!))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "fresh")
        XCTAssertEqual(http.captured.count, 2)
        XCTAssertEqual(http.captured[0].headers["Authorization"], "Bearer old")
        XCTAssertEqual(http.captured[1].headers["Authorization"], "Bearer new")
        XCTAssertEqual(provider.refreshCalls, 1)
    }

    func testSecond401AfterRefreshSurfacedToCaller() async throws {
        let http = StubHTTPClient(responses: [
            .success(401, Data()),
            .success(401, Data()),
        ])
        let provider = StubTokenProvider(accessTokens: ["a", "b"])
        let session = AuthorizedSession(client: http, provider: provider)

        let (_, response) = try await session.data(for: URLRequest(url: URL(string: "https://example/f")!))

        XCTAssertEqual(response.statusCode, 401, "second 401 must propagate, not re-refresh")
        XCTAssertEqual(http.captured.count, 2)
        XCTAssertEqual(provider.refreshCalls, 1)
    }

    func testRefreshFailureIsTerminal() async {
        let http = StubHTTPClient(response: .success(401, Data()))
        let provider = StubTokenProvider(accessTokens: ["a"], refreshError: DriveClientError.refreshFailed)
        let session = AuthorizedSession(client: http, provider: provider)

        do {
            _ = try await session.data(for: URLRequest(url: URL(string: "https://example/f")!))
            XCTFail("expected failure")
        } catch let DriveClientError.refreshFailed {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
