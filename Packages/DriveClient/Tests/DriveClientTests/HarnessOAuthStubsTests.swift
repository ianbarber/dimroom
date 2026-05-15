import XCTest
@testable import DriveClient

final class HarnessOAuthStubsTests: XCTestCase {

    func testAuthenticateFlowSucceedsEndToEnd() async throws {
        let store = InMemoryTokenStore()
        let client = DriveClient(
            config: OAuthConfig(clientID: "harness-stub-client"),
            httpClient: HarnessStubHTTPClient(),
            tokenStore: store,
            browserLauncher: HarnessStubBrowserLauncher(),
            redirectServerFactory: { LoopbackRedirectServer() }
        )

        try await client.authenticate()

        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
        XCTAssertEqual(try store.loadRefreshToken(), "stub-refresh")
    }

    func testFetchAccountEmailReturnsCannedEmail() async throws {
        let client = DriveClient(
            config: OAuthConfig(clientID: "harness-stub-client"),
            httpClient: HarnessStubHTTPClient(),
            tokenStore: InMemoryTokenStore(initial: "stub-refresh"),
            browserLauncher: HarnessStubBrowserLauncher(),
            redirectServerFactory: { LoopbackRedirectServer() }
        )

        let email = try await client.fetchAccountEmail()

        XCTAssertEqual(email, "harness@example.test")
    }

    func testFetchAccountEmailRespectsCustomEmail() async throws {
        let client = DriveClient(
            config: OAuthConfig(clientID: "harness-stub-client"),
            httpClient: HarnessStubHTTPClient(email: "tester@dimroom.test"),
            tokenStore: InMemoryTokenStore(initial: "stub-refresh"),
            browserLauncher: HarnessStubBrowserLauncher(),
            redirectServerFactory: { LoopbackRedirectServer() }
        )

        let email = try await client.fetchAccountEmail()

        XCTAssertEqual(email, "tester@dimroom.test")
    }

    func testDeauthenticateClearsTokenStore() async throws {
        let store = InMemoryTokenStore(initial: "stub-refresh")
        let client = DriveClient(
            config: OAuthConfig(clientID: "harness-stub-client"),
            httpClient: HarnessStubHTTPClient(),
            tokenStore: store,
            browserLauncher: HarnessStubBrowserLauncher(),
            redirectServerFactory: { LoopbackRedirectServer() }
        )

        var authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)

        try await client.deauthenticate()

        authenticated = await client.isAuthenticated
        XCTAssertFalse(authenticated)
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testUnknownURLReturns404() async throws {
        let stub = HarnessStubHTTPClient()
        let unexpected = URLRequest(url: URL(string: "https://example.com/nope")!)

        let (_, response) = try await stub.data(for: unexpected)

        XCTAssertEqual(response.statusCode, 404)
    }
}
