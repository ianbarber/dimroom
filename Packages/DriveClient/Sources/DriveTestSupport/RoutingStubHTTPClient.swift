import Foundation
import DriveClient

/// HTTPClient stub that dispatches on `(method, URL path + query substring)`.
/// Handles the multi-call flows (list → create → list → upload) that the
/// uploader tests rely on without the sequence-of-responses ordering
/// getting out of sync when we refactor.
public final class RoutingStubHTTPClient: HTTPClient, @unchecked Sendable {

    public struct CannedResponse {
        public let status: Int
        public let body: Data
        public let headers: [String: String]

        public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    public struct Route {
        public let method: String
        /// Substring the full URL (including query) must contain for the
        /// route to match. Kept permissive so we don't have to pin
        /// escaped-query details.
        public let urlContains: String
    }

    public struct CapturedRequest {
        public let url: URL?
        public let method: String?
        public let headers: [String: String]
        public let body: Data?
    }

    private let lock = NSLock()
    private var routes: [(Route, [CannedResponse])] = []
    private var _captured: [CapturedRequest] = []

    public init() {}

    public var captured: [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    public func route(
        method: String,
        urlContains: String,
        responses: [CannedResponse]
    ) {
        lock.lock()
        routes.append((Route(method: method, urlContains: urlContains), responses))
        lock.unlock()
    }

    public func route(method: String, urlContains: String, response: CannedResponse) {
        route(method: method, urlContains: urlContains, responses: [response])
    }

    public func requestsMatching(method: String, urlContains: String) -> [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured.filter { req in
            (req.method ?? "") == method &&
                (req.url?.absoluteString.contains(urlContains) ?? false)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        let captured = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        _captured.append(captured)

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
