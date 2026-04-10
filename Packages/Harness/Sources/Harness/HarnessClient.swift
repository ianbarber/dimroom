import Foundation
import Network
import os

/// Client that connects to the harness Unix socket, sends commands, and reads responses.
public final class HarnessClient: Sendable {
    private let socketPath: String
    private let connection: NWConnection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String = HarnessServer.defaultSocketPath) {
        self.socketPath = socketPath
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        self.connection = NWConnection(to: endpoint, using: params)
    }

    public func connect() async throws {
        let guard_ = ContinuationGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard guard_.tryConsume() else { return }
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: HarnessClientError.cancelled)
                default:
                    guard_.reset()
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    public func send(_ command: Command) async throws -> Response {
        var data = try encoder.encode(command)
        data.append(contentsOf: [UInt8(ascii: "\n")])

        // Send
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        // Receive response
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: HarnessClientError.noData)
                }
            }
        }

        // Strip trailing newline if present
        let trimmed: Data
        if responseData.last == UInt8(ascii: "\n") {
            trimmed = responseData.dropLast()
        } else {
            trimmed = responseData
        }

        return try decoder.decode(Response.self, from: trimmed)
    }

    public func disconnect() {
        connection.cancel()
    }
}

/// Thread-safe one-shot guard for continuation resumption.
private final class ContinuationGuard: Sendable {
    private let consumed = OSAllocatedUnfairLock(initialState: false)

    /// Returns `true` exactly once; subsequent calls return `false`.
    func tryConsume() -> Bool {
        consumed.withLock { flag in
            if flag { return false }
            flag = true
            return true
        }
    }

    func reset() {
        consumed.withLock { $0 = false }
    }
}

public enum HarnessClientError: Error, LocalizedError {
    case cancelled
    case noData

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Connection was cancelled"
        case .noData: return "No data received"
        }
    }
}
