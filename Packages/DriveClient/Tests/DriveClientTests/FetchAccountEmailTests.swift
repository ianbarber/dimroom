import XCTest
@testable import DriveClient

final class FetchAccountEmailTests: XCTestCase {

    func testReturnsEmailFromAboutResponse() async throws {
        let body = #"{"user":{"emailAddress":"user@example.com"}}"#
        let http = StubHTTPClient(responses: [
            // First call refreshes the access token (no cached one yet).
            .success(200, Data(#"{"access_token":"at","expires_in":3600}"#.utf8)),
            // Second call hits the about endpoint.
            .success(200, Data(body.utf8)),
        ])
        let client = makeClient(http: http, store: InMemoryTokenStore(initial: "rt"))

        let email = try await client.fetchAccountEmail()

        XCTAssertEqual(email, "user@example.com")
        let aboutRequest = http.captured.last!
        XCTAssertEqual(aboutRequest.method, "GET")
        XCTAssertEqual(
            aboutRequest.url?.absoluteString,
            "https://www.googleapis.com/drive/v3/about?fields=user/emailAddress"
        )
        XCTAssertEqual(aboutRequest.headers["Authorization"], "Bearer at")
    }

    func testReturnsNilWhenEmailFieldMissing() async throws {
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"at","expires_in":3600}"#.utf8)),
            .success(200, Data(#"{"user":{}}"#.utf8)),
        ])
        let client = makeClient(http: http, store: InMemoryTokenStore(initial: "rt"))

        let email = try await client.fetchAccountEmail()

        XCTAssertNil(email)
    }

    func testThrowsOnNon2xx() async {
        let http = StubHTTPClient(responses: [
            .success(200, Data(#"{"access_token":"at","expires_in":3600}"#.utf8)),
            .success(500, Data()),
            // AuthorizedSession does not retry 5xx, so no further responses needed.
        ])
        let client = makeClient(http: http, store: InMemoryTokenStore(initial: "rt"))

        do {
            _ = try await client.fetchAccountEmail()
            XCTFail("expected failure")
        } catch DriveClientError.downloadFailed(let status) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRetriesOnceAfter401() async throws {
        let http = StubHTTPClient(responses: [
            // Initial refresh to get an access token.
            .success(200, Data(#"{"access_token":"old","expires_in":3600}"#.utf8)),
            // First about call returns 401 → AuthorizedSession refreshes.
            .success(401, Data()),
            // Forced refresh response.
            .success(200, Data(#"{"access_token":"new","expires_in":3600}"#.utf8)),
            // Retry of about call succeeds.
            .success(200, Data(#"{"user":{"emailAddress":"u@x"}}"#.utf8)),
        ])
        let client = makeClient(http: http, store: InMemoryTokenStore(initial: "rt"))

        let email = try await client.fetchAccountEmail()

        XCTAssertEqual(email, "u@x")
        XCTAssertEqual(http.captured.count, 4)
        XCTAssertEqual(http.captured[3].headers["Authorization"], "Bearer new")
    }

    private func makeClient(http: HTTPClient, store: TokenStore) -> DriveClient {
        DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            tokenStore: store,
            browserLauncher: RecordingBrowserLauncher(),
            redirectServerFactory: { LoopbackRedirectServer() },
            verifierProvider: { "v" },
            stateProvider: { "s" }
        )
    }
}
