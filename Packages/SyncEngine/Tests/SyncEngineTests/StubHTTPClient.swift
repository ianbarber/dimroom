import Foundation
import DriveClient

/// Minimal HTTPClient stub for DriveCatalogUploader tests. Mirrors the
/// shape of the DriveClient test stubs but lives here because SPM
/// doesn't let one package's tests import another's.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct CapturedRequest {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?
    }

    enum CannedResponse {
        case success(Int, Data)
        case error(Error)
    }

    private let lock = NSLock()
    private var responses: [CannedResponse]
    private(set) var captured: [CapturedRequest] = []

    init(responses: [CannedResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        let cap = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        captured.append(cap)
        guard !responses.isEmpty else {
            lock.unlock()
            throw NSError(
                domain: "StubHTTPClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "no canned response for \(request.url?.absoluteString ?? "?")"]
            )
        }
        let response = responses.removeFirst()
        lock.unlock()
        switch response {
        case .success(let status, let data):
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, http)
        case .error(let error):
            throw error
        }
    }
}

/// Routing stub that dispatches on `(method, urlContains)`. Lets a
/// single test serve `files.list` and `files.upload` from the same
/// client without juggling FIFO ordering.
final class RoutingStubHTTPClient: HTTPClient, @unchecked Sendable {

    struct CannedResponse {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    struct CapturedRequest {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?
    }

    private struct Route {
        let method: String
        let urlContains: String
    }

    private let lock = NSLock()
    private var routes: [(Route, [CannedResponse])] = []
    private(set) var captured: [CapturedRequest] = []

    func route(method: String, urlContains: String, response: CannedResponse) {
        route(method: method, urlContains: urlContains, responses: [response])
    }

    func route(method: String, urlContains: String, responses: [CannedResponse]) {
        lock.lock()
        routes.append((Route(method: method, urlContains: urlContains), responses))
        lock.unlock()
    }

    func requestsMatching(method: String, urlContains: String) -> [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured.filter { req in
            (req.method ?? "") == method
                && (req.url?.absoluteString.contains(urlContains) ?? false)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        let cap = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        captured.append(cap)

        let method = request.httpMethod ?? ""
        let urlString = request.url?.absoluteString ?? ""
        var matchedIndex: Int?
        for (i, entry) in routes.enumerated() {
            let (route, responses) = entry
            if route.method == method, urlString.contains(route.urlContains), !responses.isEmpty {
                matchedIndex = i
                break
            }
        }
        guard let i = matchedIndex else {
            lock.unlock()
            throw NSError(
                domain: "RoutingStubHTTPClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "no route for \(method) \(urlString)"]
            )
        }
        var responses = routes[i].1
        let response = responses.removeFirst()
        routes[i] = (routes[i].0, responses)
        lock.unlock()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.body, http)
    }
}

/// StreamingHTTPClient stub: writes a canned body to the destination
/// URL and returns the canned status. Used by download tests.
final class StubStreamingHTTPClient: StreamingHTTPClient, @unchecked Sendable {
    struct CapturedDownload {
        let url: URL?
        let destination: URL
    }

    private let lock = NSLock()
    private var bodyToWrite: Data
    private var status: Int
    private(set) var captured: [CapturedDownload] = []

    init(status: Int, body: Data) {
        self.status = status
        self.bodyToWrite = body
    }

    func download(
        for request: URLRequest,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPURLResponse {
        lock.lock()
        captured.append(CapturedDownload(url: request.url, destination: destinationURL))
        let data = bodyToWrite
        let s = status
        lock.unlock()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: .atomic)
        return HTTPURLResponse(
            url: request.url!,
            statusCode: s,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

/// AccessTokenProvider stub that returns canned tokens in order.
final class StubTokenProvider: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private(set) var refreshCount = 0

    init(accessTokens: [String]) {
        self.tokens = accessTokens
    }

    func currentAccessToken() async throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !tokens.isEmpty else { return "expired" }
        return tokens.first ?? "t"
    }

    func forceRefreshAccessToken() async throws -> String {
        lock.lock(); defer { lock.unlock() }
        refreshCount += 1
        if tokens.count > 1 { tokens.removeFirst() }
        return tokens.first ?? "refreshed"
    }
}
