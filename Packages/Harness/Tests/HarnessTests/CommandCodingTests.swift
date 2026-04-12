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

    func testSelectAssetRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.selectAsset(id: id)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSetRatingRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        for rating in 0...5 {
            let command = Command.setRating(assetId: id, rating: rating)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testRotateRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.rotate(assetId: id)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSetFilterRoundTrip() throws {
        for minRating in 0...5 {
            let command = Command.setFilter(minRating: minRating)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testCopyEditRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.copyEdit(assetId: id)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testPasteEditRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        for includeCrop in [true, false] {
            let command = Command.pasteEdit(assetId: id, includeCrop: includeCrop)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testSetEditRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.setEdit(assetId: id, stateJSON: #"{"exposure":2.0}"#)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testGetEditRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.getEdit(assetId: id)
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

    func testSelectAssetJSON() throws {
        // Swift's default JSONEncoder encodes UUIDs in uppercase per
        // RFC 4122. This test pins the wire shape so downstream tools
        // (the CLI, shell flows) can rely on it.
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.selectAsset(id: id)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"id":"12345678-1234-1234-1234-123456789012","type":"selectAsset"}"#
        )
    }

    func testSetRatingJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.setRating(assetId: id, rating: 4)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","rating":4,"type":"setRating"}"#
        )
    }

    func testRotateJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.rotate(assetId: id)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","type":"rotate"}"#
        )
    }

    func testSetFilterJSON() throws {
        let command = Command.setFilter(minRating: 3)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"minRating":3,"type":"setFilter"}"#
        )
    }

    func testCopyEditJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.copyEdit(assetId: id)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","type":"copyEdit"}"#
        )
    }

    func testPasteEditJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.pasteEdit(assetId: id, includeCrop: false)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","includeCrop":false,"type":"pasteEdit"}"#
        )
    }

    func testPasteEditWithCropJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.pasteEdit(assetId: id, includeCrop: true)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","includeCrop":true,"type":"pasteEdit"}"#
        )
    }

    func testSetEditJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.setEdit(assetId: id, stateJSON: #"{"exposure":2}"#)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","stateJSON":"{\"exposure\":2}","type":"setEdit"}"#
        )
    }

    func testGetEditJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.getEdit(assetId: id)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","type":"getEdit"}"#
        )
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

    func testDecodeSelectAssetFromJSON() throws {
        let json = #"{"id":"12345678-1234-1234-1234-123456789012","type":"selectAsset"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .selectAsset(id: expected))
    }

    func testDecodeCopyEditFromJSON() throws {
        let json = #"{"type":"copyEdit","assetId":"12345678-1234-1234-1234-123456789012"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .copyEdit(assetId: expected))
    }

    func testDecodePasteEditFromJSON() throws {
        let json = #"{"type":"pasteEdit","assetId":"12345678-1234-1234-1234-123456789012","includeCrop":true}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .pasteEdit(assetId: expected, includeCrop: true))
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

    func testAppStateRoundTripWithAssetFields() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let state = AppState(
            route: .library,
            assetCount: 42,
            selectedAssetId: id,
            minRating: 4
        )
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
        XCTAssertEqual(decoded.assetCount, 42)
        XCTAssertEqual(decoded.selectedAssetId, id)
        XCTAssertEqual(decoded.minRating, 4)
    }

    func testAppStateJSONShape() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let state = AppState(
            route: .library,
            assetCount: 3,
            selectedAssetId: id,
            minRating: 3
        )
        let data = try encoder.encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetCount":3,"minRating":3,"route":"library","selectedAssetId":"12345678-1234-1234-1234-123456789012"}"#
        )
    }

    func testAppStateJSONShapeWithoutSelection() throws {
        // Swift's default JSONEncoder omits nil optionals rather than
        // emitting them as `null`. Pin that shape so the harness wire
        // format is explicit about what consumers will see. `minRating`
        // is a non-optional Int with a default of 0 and must always be
        // present in the encoded output.
        let state = AppState(route: .library, assetCount: 0, selectedAssetId: nil)
        let data = try encoder.encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetCount":0,"minRating":0,"route":"library"}"#
        )
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
