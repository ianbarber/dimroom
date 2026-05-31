import Foundation

/// Harness affordance. Drives `DriveClient.authenticate()` end-to-end
/// without a real browser by replaying the authorization redirect against
/// the real `LoopbackRedirectServer`. Production callers should never
/// construct this; the App target gates it on `DIMROOM_HARNESS_DRIVE_STUB`.
public struct HarnessStubBrowserLauncher: BrowserLauncher {
    private let code: String
    private let session: URLSession

    public init(code: String = "harness-stub-code", session: URLSession = .shared) {
        self.code = code
        self.session = session
    }

    public func open(_ url: URL) throws {
        try replayHarnessAuthorizationRedirect(
            authorizationURL: url,
            session: session
        ) { _ in
            [URLQueryItem(name: "code", value: code)]
        }
    }
}

/// Harness affordance. A `BrowserLauncher` that simulates the user
/// denying the OAuth consent screen for the first `failures` authorize
/// attempts (redirecting with `?error=access_denied`, which
/// `LoopbackRedirectServer` turns into `DriveClientError.authorizationDenied`)
/// and succeeding thereafter — delegating to the same success-redirect
/// logic as `HarnessStubBrowserLauncher`. Lets a Layer C flow reproduce
/// the #293 "failed-then-succeeded OAuth with interim imports" window.
/// Gated by the App target on `DIMROOM_HARNESS_DRIVE_STUB_FAIL_FIRST_OAUTH`.
public struct HarnessFailFirstBrowserLauncher: BrowserLauncher {
    /// `open(_:)` is the protocol's synchronous `throws` method, so the
    /// attempt counter must be synchronous. A lock-backed reference type
    /// keeps the launcher `Sendable` while letting copies of the struct
    /// share one counter (`DriveClient` may capture it by value).
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            defer { count += 1 }
            return count
        }
    }

    private let failures: Int
    private let errorCode: String
    private let code: String
    private let session: URLSession
    private let counter = AttemptCounter()

    public init(
        failures: Int,
        errorCode: String = "access_denied",
        code: String = "harness-stub-code",
        session: URLSession = .shared
    ) {
        self.failures = failures
        self.errorCode = errorCode
        self.code = code
        self.session = session
    }

    public func open(_ url: URL) throws {
        let attempt = counter.next()
        let shouldFail = attempt < failures
        try replayHarnessAuthorizationRedirect(
            authorizationURL: url,
            session: session
        ) { _ in
            if shouldFail {
                return [URLQueryItem(name: "error", value: errorCode)]
            }
            return [URLQueryItem(name: "code", value: code)]
        }
    }
}

/// Shared redirect-replay for the harness browser-launcher stubs. Parses
/// the `redirect_uri` and `state` out of the authorization URL, rebuilds
/// the loopback callback URL with `resultItems` (a `code` for success or
/// an `error` for a denied attempt) plus the round-tripped `state`, and
/// fires it against the running `LoopbackRedirectServer`. `resultItems`
/// receives the parsed `state` but stubs round-trip it via the appended
/// item below, so they ignore it.
private func replayHarnessAuthorizationRedirect(
    authorizationURL url: URL,
    session: URLSession,
    resultItems: (_ state: String?) -> [URLQueryItem]
) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let items = components.queryItems else {
        throw DriveClientError.invalidRedirect("authorization URL has no query items")
    }
    var redirectURI: String?
    var state: String?
    for item in items {
        switch item.name {
        case "redirect_uri": redirectURI = item.value
        case "state": state = item.value
        default: break
        }
    }
    guard let redirectURI, let base = URL(string: redirectURI) else {
        throw DriveClientError.invalidRedirect("authorization URL missing redirect_uri")
    }
    guard var redirectComponents = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
        throw DriveClientError.invalidRedirect("redirect_uri is not a valid URL")
    }
    var query = resultItems(state)
    if let state {
        query.append(URLQueryItem(name: "state", value: state))
    }
    redirectComponents.queryItems = query
    guard let callbackURL = redirectComponents.url else {
        throw DriveClientError.invalidRedirect("could not build callback URL")
    }
    Task.detached {
        _ = try? await session.data(for: URLRequest(url: callbackURL))
    }
}

/// Harness affordance. Returns canned token-exchange + `/about` responses
/// so `DriveClient.authenticate()` and `fetchAccountEmail()` can run in
/// harness mode with no real Google traffic. Any other URL returns HTTP
/// 404 so misuse fails loudly rather than silently.
public struct HarnessStubHTTPClient: HTTPClient {
    private let email: String
    private let accessToken: String
    private let refreshToken: String

    public init(
        email: String = "harness@example.test",
        accessToken: String = "stub-access",
        refreshToken: String = "stub-refresh"
    ) {
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            return try respond(status: 404, body: Data(), for: request)
        }
        let host = url.host ?? ""
        let path = url.path
        switch (host, path) {
        case ("oauth2.googleapis.com", "/token"):
            let body = #"{"access_token":"\#(accessToken)","refresh_token":"\#(refreshToken)","expires_in":3600,"token_type":"Bearer"}"#
            return try respond(status: 200, body: Data(body.utf8), for: request)
        case ("www.googleapis.com", "/drive/v3/about"):
            let body = #"{"user":{"emailAddress":"\#(email)"}}"#
            return try respond(status: 200, body: Data(body.utf8), for: request)
        default:
            return try respond(status: 404, body: Data(), for: request)
        }
    }

    private func respond(
        status: Int,
        body: Data,
        for request: URLRequest
    ) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }
}
