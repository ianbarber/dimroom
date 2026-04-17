import Foundation

public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Stream the response body as a sequence of `Data` chunks. Used by
    /// `DriveClient.downloadFile` to pipe Drive media into a file handle
    /// without buffering the full payload in memory. The default
    /// implementation falls back to `data(for:)` and yields one big chunk
    /// — fine for tests and small payloads, but production conformers
    /// should override.
    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
}

extension HTTPClient {
    public func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            if !data.isEmpty {
                continuation.yield(data)
            }
            continuation.finish()
        }
        return (stream, response)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let chunkSize: Int

    public init(session: URLSession = .shared, chunkSize: Int = 64 * 1024) {
        self.session = session
        self.chunkSize = chunkSize
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let chunkSize = self.chunkSize
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(chunkSize)
                    for try await byte in asyncBytes {
                        buffer.append(byte)
                        if buffer.count >= chunkSize {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (stream, http)
    }
}
