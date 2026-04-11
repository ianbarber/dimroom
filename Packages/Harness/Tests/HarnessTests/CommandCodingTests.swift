import XCTest
@testable import Harness

final class CommandCodingTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - Command round-trips

    func testNavigateRoundTrip() throws {
        for route in Route.allCases {
            let command = Command.navigate(route)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testScreenshotRoundTrip() throws {
        let command = Command.screenshot(path: "/tmp/test.png")
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testStateRoundTrip() throws {
        let command = Command.state
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testQuitRoundTrip() throws {
        let command = Command.quit
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testImportFolderRoundTrip() throws {
        let command = Command.importFolder(path: "/tmp/cards/2024-06-01")
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testListAssetsRoundTrip() throws {
        let command = Command.listAssets
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    // MARK: - Command JSON shape

    func testNavigateJSON() throws {
        let command = Command.navigate(.library)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"route":"library","type":"navigate"}"#)
    }

    func testScreenshotJSON() throws {
        let command = Command.screenshot(path: "/tmp/shot.png")
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"path":"\/tmp\/shot.png","type":"screenshot"}"#)
    }

    func testStateJSON() throws {
        let command = Command.state
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"state"}"#)
    }

    func testQuitJSON() throws {
        let command = Command.quit
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"quit"}"#)
    }

    func testImportFolderJSON() throws {
        let command = Command.importFolder(path: "/tmp/cards")
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"path":"\/tmp\/cards","type":"importFolder"}"#)
    }

    func testListAssetsJSON() throws {
        let command = Command.listAssets
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"listAssets"}"#)
    }

    // MARK: - Command decoding from raw JSON

    func testDecodeNavigateFromJSON() throws {
        let json = #"{"type":"navigate","route":"develop"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .navigate(.develop))
    }

    func testDecodeImportFolderFromJSON() throws {
        let json = #"{"type":"importFolder","path":"/var/fixtures/import"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .importFolder(path: "/var/fixtures/import"))
    }

    func testDecodeListAssetsFromJSON() throws {
        let json = #"{"type":"listAssets"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .listAssets)
    }

    // MARK: - Response round-trips

    func testResponseOkRoundTrip() throws {
        let response = Response.ok()
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response.self, from: data)
        XCTAssertEqual(decoded.status, .ok)
        XCTAssertNil(decoded.error)
    }

    func testResponseOkWithDataRoundTrip() throws {
        let response = Response.ok(data: .dictionary([
            "route": .string("library")
        ]))
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response.self, from: data)
        XCTAssertEqual(decoded.status, .ok)
        XCTAssertEqual(decoded.data, .dictionary(["route": .string("library")]))
    }

    func testResponseErrorRoundTrip() throws {
        let response = Response.error("something broke")
        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response.self, from: data)
        XCTAssertEqual(decoded.status, .error)
        XCTAssertEqual(decoded.error, "something broke")
    }

    // MARK: - AppState round-trip

    func testAppStateRoundTrip() throws {
        let state = AppState(route: .loupe)
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
    }

    // MARK: - Route

    func testRouteAllCases() {
        XCTAssertEqual(Route.allCases, [.library, .loupe, .develop])
    }

    func testRouteRawValues() {
        XCTAssertEqual(Route.library.rawValue, "library")
        XCTAssertEqual(Route.loupe.rawValue, "loupe")
        XCTAssertEqual(Route.develop.rawValue, "develop")
    }
}
