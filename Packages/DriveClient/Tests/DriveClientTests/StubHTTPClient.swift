import Foundation
@testable import DriveClient

final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    struct CapturedRequest {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?
    }

    enum Response {
        case success(Int, Data)
        case error(Error)
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var captured: [CapturedRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    convenience init(response: Response) {
        self.init(responses: [response])
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        let captured = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        self.captured.append(captured)
        guard !responses.isEmpty else {
            lock.unlock()
            throw NSError(domain: "StubHTTPClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "no canned response"])
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

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return captured.count
    }
}
