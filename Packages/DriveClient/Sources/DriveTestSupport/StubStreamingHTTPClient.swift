import Foundation
import DriveClient

public final class StubStreamingHTTPClient: StreamingHTTPClient, @unchecked Sendable {
    public struct CapturedRequest {
        public let url: URL?
        public let method: String?
        public let headers: [String: String]
        public let destination: URL
    }

    public struct Response {
        public let status: Int
        public let chunks: [Data]
        public let error: Error?

        public static func success(_ status: Int, chunks: [Data]) -> Response {
            Response(status: status, chunks: chunks, error: nil)
        }

        public static func success(_ status: Int, data: Data) -> Response {
            Response(status: status, chunks: [data], error: nil)
        }

        /// Writes `chunks` to the destination and then throws `error`,
        /// simulating a connection drop or server RST after bytes have already
        /// landed on disk. Pass a 2xx `status` so the stub takes its write path
        /// before the throw — that's the case that leaves a `.partial` temp
        /// file for the caller's cleanup to reclaim.
        public static func streamFailure(_ status: Int, chunks: [Data], error: Error) -> Response {
            Response(status: status, chunks: chunks, error: error)
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var _captured: [CapturedRequest] = []

    public init(responses: [Response]) {
        self.responses = responses
    }

    public convenience init(status: Int, body: Data) {
        self.init(responses: [.success(status, data: body)])
    }

    public var captured: [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    public func download(
        for request: URLRequest,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPURLResponse {
        lock.lock()
        _captured.append(
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
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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

        // Surface a mid-stream failure after the bytes already written above
        // are flushed and the handle is closed (its `defer` ran when the block
        // exited). The caller sees a throw with the temp file present on disk.
        if let error = response.error {
            throw error
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
