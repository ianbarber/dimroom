import Foundation
@testable import DriveClient

final class StubStreamingHTTPClient: StreamingHTTPClient, @unchecked Sendable {
    struct CapturedRequest {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let destination: URL
    }

    struct Response {
        let status: Int
        let chunks: [Data]

        static func success(_ status: Int, chunks: [Data]) -> Response {
            Response(status: status, chunks: chunks)
        }

        static func success(_ status: Int, data: Data) -> Response {
            Response(status: status, chunks: [data])
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var captured: [CapturedRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func download(
        for request: URLRequest,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPURLResponse {
        lock.lock()
        captured.append(
            CapturedRequest(
                url: request.url,
                method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
                destination: destinationURL
            )
        )
        guard !responses.isEmpty else {
            lock.unlock()
            throw NSError(
                domain: "StubStreamingHTTPClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "no canned response"]
            )
        }
        let response = responses.removeFirst()
        lock.unlock()

        let total = response.chunks.reduce(0) { $0 + $1.count }
        if (200..<300).contains(response.status) {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }
            var written = 0
            for chunk in response.chunks {
                try handle.write(contentsOf: chunk)
                written += chunk.count
                if let progress, total > 0 {
                    progress(Double(written) / Double(total))
                }
            }
        }

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return http
    }
}
