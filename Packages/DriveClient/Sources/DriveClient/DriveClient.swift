import Foundation

public actor DriveClient {
    public struct AuthenticateOptions: Sendable {
        public var timeout: TimeInterval
        public var state: String?
        public init(timeout: TimeInterval = 120, state: String? = nil) {
            self.timeout = timeout
            self.state = state
        }
    }

    private let config: OAuthConfig
    private let httpClient: HTTPClient
    private let streamingClient: StreamingHTTPClient
    private let tokenStore: TokenStore
    private let browserLauncher: BrowserLauncher
    private let redirectServerFactory: @Sendable () -> LoopbackRedirectServer
    private let verifierProvider: @Sendable () -> String
    private let stateProvider: @Sendable () -> String

    private var cachedAccessToken: String?
    private var accessTokenExpiresAt: Date?

    /// Fires once per `refreshAccessToken()` failure. Every authorized
    /// request funnels through `refreshAccessToken` (directly or via
    /// `AuthorizedSession`'s `forceRefreshAccessToken` path), so a single
    /// stream covers `accessToken()`, `fetchAccountEmail`, `downloadFile`,
    /// and the upload paths. `DriveAuthState` subscribes to flip the UI
    /// back to `.disconnected` when a stale/revoked refresh token surfaces.
    public nonisolated let authFailures: AsyncStream<Void>
    private nonisolated let failureContinuation: AsyncStream<Void>.Continuation

    public init(
        config: OAuthConfig,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        streamingClient: StreamingHTTPClient = URLSessionStreamingHTTPClient(),
        tokenStore: TokenStore = KeychainTokenStore(),
        browserLauncher: BrowserLauncher = NSWorkspaceBrowserLauncher(),
        redirectServerFactory: @escaping @Sendable () -> LoopbackRedirectServer = { LoopbackRedirectServer() },
        verifierProvider: @escaping @Sendable () -> String = { PKCE.generateVerifier() },
        stateProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.config = config
        self.httpClient = httpClient
        self.streamingClient = streamingClient
        self.tokenStore = tokenStore
        self.browserLauncher = browserLauncher
        self.redirectServerFactory = redirectServerFactory
        self.verifierProvider = verifierProvider
        self.stateProvider = stateProvider
        var continuation: AsyncStream<Void>.Continuation!
        self.authFailures = AsyncStream { continuation = $0 }
        self.failureContinuation = continuation
    }

    public var isAuthenticated: Bool {
        get async {
            ((try? tokenStore.loadRefreshToken()) ?? nil) != nil
        }
    }

    public func accessToken() async throws -> String {
        if let cachedAccessToken, let expiresAt = accessTokenExpiresAt, expiresAt > Date().addingTimeInterval(30) {
            return cachedAccessToken
        }
        return try await refreshAccessToken()
    }

    @discardableResult
    public func refreshAccessToken() async throws -> String {
        guard let refreshToken = try tokenStore.loadRefreshToken() else {
            throw DriveClientError.notAuthenticated
        }
        let response: TokenResponse
        do {
            response = try await TokenEndpoint.refresh(refreshToken: refreshToken, config: config, client: httpClient)
        } catch {
            failureContinuation.yield()
            throw DriveClientError.refreshFailed
        }
        applyTokenResponse(response)
        if let newRefresh = response.refresh_token {
            try tokenStore.save(refreshToken: newRefresh)
        }
        return response.access_token
    }

    public func deauthenticate() async throws {
        try tokenStore.clear()
        cachedAccessToken = nil
        accessTokenExpiresAt = nil
    }

    /// `GET /drive/v3/about?fields=user/emailAddress` — returns the Google
    /// account email associated with the current refresh token, or `nil`
    /// when the response omits the field. Used by the UI to label the
    /// connected state ("Disconnect (user@example.com)").
    public func fetchAccountEmail() async throws -> String? {
        let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user/emailAddress")!
        let request = URLRequest(url: url)
        let session = AuthorizedSession(client: httpClient, provider: self)
        let (data, response) = try await session.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw DriveClientError.downloadFailed(status: response.statusCode)
        }
        struct AboutResponse: Decodable {
            struct User: Decodable {
                let emailAddress: String?
            }
            let user: User?
        }
        let decoded = try JSONDecoder().decode(AboutResponse.self, from: data)
        return decoded.user?.emailAddress
    }

    /// Download a Drive file's media to `destinationURL`. Streams bytes to a
    /// temp file via `StreamingHTTPClient` so originals — often 50–100MB+ RAW
    /// or TIFF — never have to live entirely in memory. Progress fires
    /// incrementally from the URLSession delegate and a final 1.0 tick once
    /// the file is in place.
    public func downloadFile(
        id: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        let request = URLRequest(url: url)
        let session = AuthorizedSession(
            client: httpClient,
            streamingClient: streamingClient,
            provider: self
        )
        let response = try await session.download(for: request, to: destinationURL, progress: progress)
        guard response.statusCode == 200 else {
            throw DriveClientError.downloadFailed(status: response.statusCode)
        }
        progress?(1.0)
    }

    public func authenticate(options: AuthenticateOptions = AuthenticateOptions()) async throws {
        let server = redirectServerFactory()
        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            await server.stop()
            throw error
        }
        let redirectURI = "http://127.0.0.1:\(port)/"
        let verifier = verifierProvider()
        let state = options.state ?? stateProvider()
        let authURL = buildAuthorizationURL(redirectURI: redirectURI, verifier: verifier, state: state)

        do {
            try browserLauncher.open(authURL)
        } catch {
            await server.stop()
            throw error
        }

        let redirect: LoopbackRedirect
        do {
            redirect = try await withTimeout(options.timeout) {
                try await server.waitForRedirect()
            }
        } catch is TimeoutError {
            await server.stop()
            throw DriveClientError.authorizationTimedOut
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        if let received = redirect.state, received != state {
            throw DriveClientError.stateMismatch
        }

        let response = try await TokenEndpoint.exchange(
            code: redirect.code,
            verifier: verifier,
            redirectURI: redirectURI,
            config: config,
            client: httpClient
        )
        applyTokenResponse(response)
        if let refresh = response.refresh_token {
            try tokenStore.save(refreshToken: refresh)
        }
    }

    func buildAuthorizationURL(redirectURI: String, verifier: String, state: String) -> URL {
        var components = URLComponents(url: config.authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scope),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    private func applyTokenResponse(_ response: TokenResponse) {
        cachedAccessToken = response.access_token
        if let expiresIn = response.expires_in {
            accessTokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            accessTokenExpiresAt = nil
        }
    }
}

extension DriveClient: AccessTokenProvider {
    public func currentAccessToken() async throws -> String {
        try await accessToken()
    }

    public func forceRefreshAccessToken() async throws -> String {
        try await refreshAccessToken()
    }
}

private struct TimeoutError: Error {}

private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
