import Foundation
import DriveClient

public final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    public struct CapturedRequest {
        public let url: URL?
        public let method: String?
        public let headers: [String: String]
        public let body: Data?
    }

    public enum Response {
        case success(Int, Data)
        case error(Error)
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var _captured: [CapturedRequest] = []

    public init(responses: [Response]) {
        self.responses = responses
    }

    public convenience init(response: Response) {
        self.init(responses: [response])
    }

    public var captured: [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    public var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _captured.count
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
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, http)
        case .error(let error):
            throw error
        }
    }
}
