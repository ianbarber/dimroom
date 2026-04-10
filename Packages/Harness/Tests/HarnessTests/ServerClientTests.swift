import XCTest
@testable import Harness

final class ServerClientTests: XCTestCase {
    private let socketPath = "/tmp/dimroom-harness-test-\(ProcessInfo.processInfo.processIdentifier).sock"

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testServerClientStateCommand() async throws {
        let handler: CommandHandler = { command in
            switch command {
            case .state:
                return .ok(data: .dictionary(["route": .string("library")]))
            default:
                return .error("unexpected command")
            }
        }

        let server = try HarnessServer(socketPath: socketPath, handler: handler)
        server.start()
        try await Task.sleep(for: .milliseconds(200))

        let client = HarnessClient(socketPath: socketPath)
        try await client.connect()

        let response = try await client.send(.state)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.data, .dictionary(["route": .string("library")]))

        client.disconnect()
        server.stop()
    }

    func testServerClientNavigateCommand() async throws {
        let box = SendableBox<Route>()
        let handler: CommandHandler = { command in
            switch command {
            case .navigate(let route):
                box.value = route
                return .ok()
            default:
                return .error("unexpected command")
            }
        }

        let server = try HarnessServer(socketPath: socketPath, handler: handler)
        server.start()
        try await Task.sleep(for: .milliseconds(200))

        let client = HarnessClient(socketPath: socketPath)
        try await client.connect()

        let response = try await client.send(.navigate(.develop))
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(box.value, .develop)

        client.disconnect()
        server.stop()
    }

    func testServerClientQuitCommand() async throws {
        let box = SendableBox<Bool>()
        let handler: CommandHandler = { command in
            switch command {
            case .quit:
                box.value = true
                return .ok()
            default:
                return .error("unexpected command")
            }
        }

        let server = try HarnessServer(socketPath: socketPath, handler: handler)
        server.start()
        try await Task.sleep(for: .milliseconds(200))

        let client = HarnessClient(socketPath: socketPath)
        try await client.connect()

        let response = try await client.send(.quit)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(box.value, true)

        client.disconnect()
        server.stop()
    }

    func testSocketCleanupOnStop() async throws {
        let handler: CommandHandler = { _ in .ok() }
        let server = try HarnessServer(socketPath: socketPath, handler: handler)
        server.start()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}

/// Thread-safe box for capturing values in Sendable closures during tests.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T?
}
