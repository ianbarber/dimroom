import XCTest
@testable import DriveClient

final class DriveClientTests: XCTestCase {
    func testAuthenticateHappyPath() async throws {
        let tokenJSON = #"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"Bearer"}"#
        let http = StubHTTPClient(response: .success(200, Data(tokenJSON.utf8)))
        let store = InMemoryTokenStore()

        let server = LoopbackRedirectServer()
        let launcher = RecordingBrowserLauncher()
        launcher.onOpen = { url in
            Task {
                try? await postRedirect(to: url, code: "auth-code", state: "fixed-state")
            }
        }

        let config = OAuthConfig(clientID: "client-123")
        let client = DriveClient(
            config: config,
            httpClient: http,
            tokenStore: store,
            browserLauncher: launcher,
            redirectServerFactory: { server },
            verifierProvider: { "fixed-verifier" },
            stateProvider: { "fixed-state" }
        )

        try await client.authenticate()

        XCTAssertEqual(try store.loadRefreshToken(), "rt-1")
        let token = try await client.accessToken()
        XCTAssertEqual(token, "at-1", "cached access token should be returned without another refresh")
        XCTAssertEqual(http.captured.count, 1, "only the initial exchange should be called")

        let authURL = try XCTUnwrap(launcher.openedURL)
        let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(params["client_id"], "client-123")
        XCTAssertEqual(params["code_challenge"], PKCE.challenge(for: "fixed-verifier"))
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["response_type"], "code")
        XCTAssertEqual(params["state"], "fixed-state")
        XCTAssertEqual(params["access_type"], "offline")

        let body = String(data: try XCTUnwrap(http.captured.first?.body), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("code_verifier=fixed-verifier"))
        XCTAssertTrue(body.contains("code=auth-code"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
    }

    func testIsAuthenticatedReflectsStoredRefreshToken() async throws {
        let populated = makeClient(store: InMemoryTokenStore(initial: "rt"))
        let authedPopulated = await populated.isAuthenticated
        XCTAssertTrue(authedPopulated)

        let empty = makeClient(store: InMemoryTokenStore())
        let authedEmpty = await empty.isAuthenticated
        XCTAssertFalse(authedEmpty)
    }

    func testDeauthenticateClearsStore() async throws {
        let store = InMemoryTokenStore(initial: "rt")
        let client = makeClient(store: store)
        try await client.deauthenticate()
        XCTAssertNil(try store.loadRefreshToken())
    }

    func testRefreshAccessTokenUsesStoredRefreshToken() async throws {
        let tokenJSON = #"{"access_token":"new-at","expires_in":3600}"#
        let http = StubHTTPClient(response: .success(200, Data(tokenJSON.utf8)))
        let store = InMemoryTokenStore(initial: "stored-rt")
        let client = makeClient(http: http, store: store)

        let token = try await client.refreshAccessToken()

        XCTAssertEqual(token, "new-at")
        let body = String(data: try XCTUnwrap(http.captured.first?.body), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("refresh_token=stored-rt"))
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
    }

    func testRefreshWithoutStoredTokenThrowsNotAuthenticated() async {
        let client = makeClient(store: InMemoryTokenStore())
        do {
            _ = try await client.refreshAccessToken()
            XCTFail("expected failure")
        } catch DriveClientError.notAuthenticated {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStateMismatchDuringAuthenticateThrows() async throws {
        let tokenJSON = #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#
        let http = StubHTTPClient(response: .success(200, Data(tokenJSON.utf8)))
        let store = InMemoryTokenStore()

        let server = LoopbackRedirectServer()
        let launcher = RecordingBrowserLauncher()
        launcher.onOpen = { url in
            Task {
                try? await postRedirect(to: url, code: "c", state: "WRONG")
            }
        }

        let client = DriveClient(
            config: OAuthConfig(clientID: "cid"),
            httpClient: http,
            tokenStore: store,
            browserLauncher: launcher,
            redirectServerFactory: { server },
            verifierProvider: { "v" },
            stateProvider: { "EXPECTED" }
        )

        do {
            try await client.authenticate()
            XCTFail("expected failure")
        } catch DriveClientError.stateMismatch {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNil(try store.loadRefreshToken())
    }

    // MARK: - helpers

    private func makeClient(
        http: HTTPClient = StubHTTPClient(responses: []),
        store: TokenStore
    ) -> DriveClient {
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

final class RecordingBrowserLauncher: BrowserLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var _onOpen: ((URL) -> Void)?
    private var _openedURL: URL?

    var onOpen: ((URL) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOpen }
        set { lock.lock(); defer { lock.unlock() }; _onOpen = newValue }
    }

    var openedURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _openedURL
    }

    func open(_ url: URL) throws {
        lock.lock()
        _openedURL = url
        let handler = _onOpen
        lock.unlock()
        handler?(url)
    }
}

private func postRedirect(to authURL: URL, code: String, state: String) async throws {
    let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
    let params = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    guard let redirectURI = params["redirect_uri"], let url = URL(string: redirectURI) else {
        throw NSError(domain: "DriveClientTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no redirect_uri"])
    }
    var components2 = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components2.queryItems = [
        URLQueryItem(name: "code", value: code),
        URLQueryItem(name: "state", value: state),
    ]
    let request = URLRequest(url: components2.url!)
    _ = try await URLSession.shared.data(for: request)
}
