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

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
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
            let chunks = Self.chunked(data, into: 4)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(data.count)"]
            )!
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            return (stream, http)
        case .error(let error):
            throw error
        }
    }

    /// Split `data` into roughly `count` equal pieces so streaming
    /// consumers see multiple progress ticks. Returns `[]` for empty
    /// input and a single chunk when the payload is shorter than the
    /// requested split count.
    private static func chunked(_ data: Data, into count: Int) -> [Data] {
        guard !data.isEmpty else { return [] }
        guard count > 1, data.count >= count else { return [data] }
        let chunkSize = max(1, data.count / count)
        var result: [Data] = []
        var index = 0
        while index < data.count {
            let end = min(index + chunkSize, data.count)
            result.append(data.subdata(in: index..<end))
            index = end
        }
        return result
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return captured.count
    }
}
