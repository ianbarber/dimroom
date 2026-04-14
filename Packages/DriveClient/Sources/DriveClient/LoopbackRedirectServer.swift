import Foundation
import Network

public struct LoopbackRedirect: Equatable {
    public let code: String
    public let state: String?
}

public actor LoopbackRedirectServer {
    public struct Options {
        public var successBody: String
        public var errorBody: String
        public init(
            successBody: String = "Dimroom: authorization complete. You can close this tab.",
            errorBody: String = "Dimroom: authorization failed."
        ) {
            self.successBody = successBody
            self.errorBody = errorBody
        }
    }

    private let options: Options
    private var listener: NWListener?
    private var port: UInt16?
    private var continuation: CheckedContinuation<LoopbackRedirect, Error>?
    private var finished = false

    public init(options: Options = Options()) {
        self.options = options
    }

    public func start() async throws -> UInt16 {
        guard listener == nil else {
            if let port { return port }
            throw DriveClientError.redirectServerFailed("listener in inconsistent state")
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw DriveClientError.redirectServerFailed(String(describing: error))
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        let resolvedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        box.resume(returning: port)
                    } else {
                        box.resume(throwing: DriveClientError.redirectServerFailed("listener has no port"))
                    }
                case .failed(let error):
                    box.resume(throwing: DriveClientError.redirectServerFailed(String(describing: error)))
                case .cancelled:
                    box.resume(throwing: DriveClientError.redirectServerFailed("listener cancelled before ready"))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        self.listener = listener
        self.port = resolvedPort
        return resolvedPort
    }

    public func waitForRedirect() async throws -> LoopbackRedirect {
        try await withCheckedThrowingContinuation { cont in
            if finished {
                cont.resume(throwing: DriveClientError.redirectServerFailed("server already finished"))
                return
            }
            self.continuation = cont
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: CancellationError())
        }
        finished = true
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection: connection, accumulated: Data())
    }

    private nonisolated func receive(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Task { await self.finish(with: .failure(DriveClientError.redirectServerFailed(String(describing: error))), connection: connection) }
                return
            }
            var combined = accumulated
            if let data { combined.append(data) }
            if let headerEnd = combined.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = combined.subdata(in: 0..<headerEnd.lowerBound)
                Task { await self.process(headerData: headerData, connection: connection) }
                return
            }
            if isComplete {
                Task { await self.finish(with: .failure(DriveClientError.invalidRedirect("no HTTP headers")), connection: connection) }
                return
            }
            self.receive(connection: connection, accumulated: combined)
        }
    }

    private func process(headerData: Data, connection: NWConnection) async {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            await finish(with: .failure(DriveClientError.invalidRedirect("headers not utf8")), connection: connection)
            return
        }
        guard let firstLine = headerString.split(separator: "\r\n").first else {
            await finish(with: .failure(DriveClientError.invalidRedirect("empty request")), connection: connection)
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            await finish(with: .failure(DriveClientError.invalidRedirect("bad request line")), connection: connection)
            return
        }
        let target = String(parts[1])
        let query = Self.parseQuery(from: target)
        if let error = query["error"] {
            await finish(with: .failure(DriveClientError.authorizationDenied(error)), connection: connection)
            return
        }
        guard let code = query["code"], !code.isEmpty else {
            await finish(with: .failure(DriveClientError.invalidRedirect("missing code")), connection: connection)
            return
        }
        let redirect = LoopbackRedirect(code: code, state: query["state"])
        await finish(with: .success(redirect), connection: connection)
    }

    private func finish(with result: Result<LoopbackRedirect, Error>, connection: NWConnection) async {
        let body: String
        let statusLine: String
        switch result {
        case .success:
            body = options.successBody
            statusLine = "HTTP/1.1 200 OK"
        case .failure:
            body = options.errorBody
            statusLine = "HTTP/1.1 400 Bad Request"
        }
        let response = "\(statusLine)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        if finished { return }
        finished = true
        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UInt16, Error>?

        init(_ continuation: CheckedContinuation<UInt16, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: UInt16) {
            lock.lock(); defer { lock.unlock() }
            guard let c = continuation else { return }
            continuation = nil
            c.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock(); defer { lock.unlock() }
            guard let c = continuation else { return }
            continuation = nil
            c.resume(throwing: error)
        }
    }

    static func parseQuery(from target: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let questionIndex = target.firstIndex(of: "?") else { return result }
        let queryStart = target.index(after: questionIndex)
        let queryString = target[queryStart...]
        for pair in queryString.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = components.first?.removingPercentEncoding else { continue }
            let value = components.count > 1 ? (components[1].removingPercentEncoding ?? "") : ""
            result[String(key)] = value
        }
        return result
    }
}
