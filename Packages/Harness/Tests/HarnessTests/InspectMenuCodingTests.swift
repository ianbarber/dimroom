import XCTest
@testable import Harness

/// Layer A round-trip tests for the `inspectMenu` harness command.
///
/// This command exists so the Layer C `harness-multi-select-delete-flow.sh`
/// can assert that the Edit → Delete Selected menu item is wired up with the
/// Backspace shortcut and tracks selection state — closing the regression
/// gap left when PR #179 omitted the menu introspection promised in #134's
/// plan. See issue #183 for the full rationale.
///
/// Why an in-process command rather than `osascript` / System Events:
/// in-process inspection requires no Accessibility permission, runs
/// deterministically in CI, and keeps the assertion close to the same
/// `NSApplication.mainMenu` the user actually sees.
final class InspectMenuCodingTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
    private let decoder = JSONDecoder()

    func testInspectMenuRoundTrip() throws {
        let command = Command.inspectMenu(title: "Edit")
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testInspectMenuJSON() throws {
        let command = Command.inspectMenu(title: "Edit")
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"title":"Edit","type":"inspectMenu"}"#)
    }

    func testDecodeInspectMenuFromJSON() throws {
        let json = #"{"type":"inspectMenu","title":"File"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .inspectMenu(title: "File"))
    }
}
