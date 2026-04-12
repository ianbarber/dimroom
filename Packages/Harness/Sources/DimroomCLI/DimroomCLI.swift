import ArgumentParser
import Foundation
import Harness

@main
struct DimroomCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dimroom-cli",
        abstract: "Command-line interface for the Dimroom harness socket.",
        subcommands: [
            Navigate.self,
            Screenshot.self,
            State.self,
            Quit.self,
            ImportFolder.self,
            ListAssets.self,
            SelectAsset.self,
        ]
    )
}

extension DimroomCLI {
    struct Navigate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Navigate to a route.")

        @Argument(help: "The route to navigate to (library, loupe, develop).")
        var route: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let r = Route(rawValue: route) else {
                throw ValidationError("Invalid route '\(route)'. Valid: \(Route.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            try runCommand(.navigate(r), socket: socket)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture a screenshot.")

        @Argument(help: "File path to write the PNG screenshot.")
        var path: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.screenshot(path: path), socket: socket)
        }
    }

    struct State: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get current app state.")

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.state, socket: socket)
        }
    }

    struct Quit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Quit the app.")

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.quit, socket: socket)
        }
    }

    struct ImportFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-folder",
            abstract: "Import all supported files from a folder into the catalog."
        )

        @Argument(help: "Absolute path to the folder to import.")
        var path: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.importFolder(path: path), socket: socket)
        }
    }

    struct ListAssets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list-assets",
            abstract: "List all assets currently in the catalog."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.listAssets, socket: socket)
        }
    }

    struct SelectAsset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-asset",
            abstract: "Set the library's single-selection to the given asset UUID."
        )

        @Argument(help: "The UUID of the asset to select.")
        var id: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.selectAsset(id: uuid), socket: socket)
        }
    }
}

private func runCommand(_ command: Command, socket: String) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SendableBox<Result<Response, Error>>()

    Task {
        do {
            let client = HarnessClient(socketPath: socket)
            try await client.connect()
            let response = try await client.send(command)
            client.disconnect()
            box.value = .success(response)
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()

    switch box.value! {
    case .success(let response):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        print(String(data: data, encoding: .utf8)!)
    case .failure(let error):
        throw error
    }
}

/// Thread-safe box for capturing values in Sendable closures.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T?
}
