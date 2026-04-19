import Foundation

/// Streams a response body directly to `destinationURL`, reporting progress as
/// bytes land on disk. Split out from `HTTPClient` so the JSON API surface can
/// keep its buffered `(Data, HTTPURLResponse)` shape — only large media
/// downloads need the delegate-driven path.
public protocol StreamingHTTPClient: Sendable {
    func download(
        for request: URLRequest,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPURLResponse
}

public struct URLSessionStreamingHTTPClient: StreamingHTTPClient {
    public init() {}

    public func download(
        for request: URLRequest,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> HTTPURLResponse {
        let delegate = StreamingDownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.badServerResponse)
        }

        // URLSession deletes `tempURL` once this call returns, so move it to
        // the caller's destination synchronously before we drop the scope.
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return http
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let progress else { return }
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock(); defer { lock.unlock() }
        progress(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The default implementation handles async/await delivery of the temp
        // URL; nothing else to do here. Progress callback emits 1.0 from the
        // DriveClient layer after the move succeeds, so the caller sees a
        // terminal tick even when the server didn't send Content-Length.
    }
}
