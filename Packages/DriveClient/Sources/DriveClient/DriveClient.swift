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
    private let tokenStore: TokenStore
    private let browserLauncher: BrowserLauncher
    private let redirectServerFactory: @Sendable () -> LoopbackRedirectServer
    private let verifierProvider: @Sendable () -> String
    private let stateProvider: @Sendable () -> String

    private var cachedAccessToken: String?
    private var accessTokenExpiresAt: Date?

    public init(
        config: OAuthConfig,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        tokenStore: TokenStore = KeychainTokenStore(),
        browserLauncher: BrowserLauncher = NSWorkspaceBrowserLauncher(),
        redirectServerFactory: @escaping @Sendable () -> LoopbackRedirectServer = { LoopbackRedirectServer() },
        verifierProvider: @escaping @Sendable () -> String = { PKCE.generateVerifier() },
        stateProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.config = config
        self.httpClient = httpClient
        self.tokenStore = tokenStore
        self.browserLauncher = browserLauncher
        self.redirectServerFactory = redirectServerFactory
        self.verifierProvider = verifierProvider
        self.stateProvider = stateProvider
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

    /// Download a Drive file's media to `destinationURL`. Issues
    /// `GET files/{id}?alt=media` through `AuthorizedSession` and streams
    /// the body into a sibling `.part` file, then atomically swaps it
    /// into place on success. The partial file is removed on any failure
    /// so a half-downloaded RAW never masquerades as the real thing.
    /// Progress fires per chunk as `bytesReceived / Content-Length` when
    /// the server reports a length; otherwise it ticks `0.0` at the start
    /// and `1.0` at completion.
    public func downloadFile(
        id: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        let request = URLRequest(url: url)
        let session = AuthorizedSession(client: httpClient, provider: self)
        let (stream, response) = try await session.bytes(for: request)
        guard response.statusCode == 200 else {
            throw DriveClientError.downloadFailed(status: response.statusCode)
        }

        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let partURL = destinationURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)
        guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: partURL)

        let expectedBytes = response.expectedContentLength
        let knownLength = expectedBytes > 0
        if !knownLength {
            progress?(0.0)
        }
        var bytesReceived: Int64 = 0

        do {
            for try await chunk in stream {
                try handle.write(contentsOf: chunk)
                bytesReceived += Int64(chunk.count)
                if knownLength {
                    let value = min(Double(bytesReceived) / Double(expectedBytes), 1.0)
                    progress?(value)
                }
            }
            try handle.close()
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: partURL)
            } else {
                try FileManager.default.moveItem(at: partURL, to: destinationURL)
            }
            progress?(1.0)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
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
