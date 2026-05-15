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
        var query: [URLQueryItem] = [URLQueryItem(name: "code", value: code)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state))
        }
        redirectComponents.queryItems = query
        guard let callbackURL = redirectComponents.url else {
            throw DriveClientError.invalidRedirect("could not build callback URL")
        }
        let session = self.session
        Task.detached {
            _ = try? await session.data(for: URLRequest(url: callbackURL))
        }
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
