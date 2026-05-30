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

    // MARK: - HarnessFailFirstBrowserLauncher (#371)

    /// The fail-first launcher denies the first authorize attempt
    /// (`?error=access_denied` → `authorizationDenied`) and succeeds on
    /// the second, without persisting a token for the denied attempt.
    /// This is the seam the Layer C imports-survival flow drives.
    func testFailFirstLauncherDeniesFirstAttemptThenSucceeds() async throws {
        let store = InMemoryTokenStore()
        let client = DriveClient(
            config: OAuthConfig(clientID: "harness-stub-client"),
            httpClient: HarnessStubHTTPClient(),
            tokenStore: store,
            browserLauncher: HarnessFailFirstBrowserLauncher(failures: 1),
            redirectServerFactory: { LoopbackRedirectServer() }
        )

        do {
            try await client.authenticate()
            XCTFail("expected first authenticate() to throw authorizationDenied")
        } catch let error as DriveClientError {
            guard case .authorizationDenied = error else {
                return XCTFail("expected authorizationDenied, got \(error)")
            }
        }

        var authenticated = await client.isAuthenticated
        XCTAssertFalse(authenticated, "denied attempt must not persist a refresh token")
        XCTAssertNil(try store.loadRefreshToken())

        try await client.authenticate()

        authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
        XCTAssertEqual(try store.loadRefreshToken(), "stub-refresh")
    }

    /// `failures: 2` denies twice before succeeding — pins that the
    /// counter advances per call rather than being a one-shot boolean.
    func testFailFirstLauncherDeniesTwoAttemptsThenSucceeds() async throws {
        let client = DriveClient(
            config: OAuthConfig(clientID: "harness-stub-client"),
            httpClient: HarnessStubHTTPClient(),
            tokenStore: InMemoryTokenStore(),
            browserLauncher: HarnessFailFirstBrowserLauncher(failures: 2),
            redirectServerFactory: { LoopbackRedirectServer() }
        )

        for attempt in 1...2 {
            do {
                try await client.authenticate()
                XCTFail("expected attempt \(attempt) to throw authorizationDenied")
            } catch let error as DriveClientError {
                guard case .authorizationDenied = error else {
                    return XCTFail("attempt \(attempt): expected authorizationDenied, got \(error)")
                }
            }
        }

        try await client.authenticate()

        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
    }
}
