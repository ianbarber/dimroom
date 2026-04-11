import Foundation
import Network

/// Unix domain socket server that accepts newline-delimited JSON commands.
public final class HarnessServer: Sendable {
    public static let defaultSocketPath = "/tmp/dimroom-harness.sock"

    private let socketPath: String
    private let handler: CommandHandler
    private let listener: NWListener
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String = HarnessServer.defaultSocketPath, handler: @escaping CommandHandler) throws {
        self.socketPath = socketPath
        self.handler = handler

        // Remove stale socket file if it exists
        let fm = FileManager.default
        if fm.fileExists(atPath: socketPath) {
            try fm.removeItem(atPath: socketPath)
        }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        self.listener = try NWListener(using: params)
    }

    public func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                break
            case .failed(let error):
                print("[Harness] Listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(connection: connection)
    }

    private func receiveLoop(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.processData(data, connection: connection)
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveLoop(connection: connection)
        }
    }

    private func processData(_ data: Data, connection: NWConnection) {
        // Split by newlines — each line is one JSON command
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let lineData = Data(line.utf8)
            do {
                let command = try decoder.decode(Command.self, from: lineData)
                Task {
                    do {
                        let response = try await self.handler(command)
                        self.sendResponse(response, on: connection)
                    } catch {
                        self.sendResponse(.error(error.localizedDescription), on: connection)
                    }
                }
            } catch {
                sendResponse(.error("Invalid command: \(error.localizedDescription)"), on: connection)
            }
        }
    }

    private func sendResponse(_ response: Response, on connection: NWConnection) {
        do {
            var data = try encoder.encode(response)
            data.append(contentsOf: [UInt8(ascii: "\n")])
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("[Harness] Send error: \(error)")
                }
            })
        } catch {
            print("[Harness] Encode error: \(error)")
        }
    }
}
