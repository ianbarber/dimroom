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
        for direction in ["cw", "ccw"] {
            let command = Command.rotate(assetId: id, direction: direction)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testGoBackRoundTrip() throws {
        let command = Command.goBack
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

    func testSetCropRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.setCrop(
            assetId: id,
            x: 0.125,
            y: 0.0,
            width: 0.75,
            height: 1.0,
            angle: 5.5
        )
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSetCropJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.setCrop(
            assetId: id,
            x: 0.125,
            y: 0.0,
            width: 0.75,
            height: 1.0,
            angle: 0.0
        )
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"angle":0,"assetId":"12345678-1234-1234-1234-123456789012","height":1,"type":"setCrop","width":0.75,"x":0.125,"y":0}"#
        )
    }

    func testDecodeSetCropFromJSON() throws {
        let json = #"{"type":"setCrop","assetId":"12345678-1234-1234-1234-123456789012","x":0.1,"y":0.2,"width":0.5,"height":0.6,"angle":-10.0}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(
            command,
            .setCrop(assetId: expected, x: 0.1, y: 0.2, width: 0.5, height: 0.6, angle: -10.0)
        )
    }

    func testSetEditParameterRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        for (parameter, value) in [("exposure", 2.0), ("contrast", -0.5), ("temperature", 5500.0)] {
            let command = Command.setEditParameter(assetId: id, parameter: parameter, value: value)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testSetEditParameterJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.setEditParameter(assetId: id, parameter: "exposure", value: 2.0)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","parameter":"exposure","type":"setEditParameter","value":2}"#
        )
    }

    func testDecodeSetEditParameterFromJSON() throws {
        let json = #"{"type":"setEditParameter","assetId":"12345678-1234-1234-1234-123456789012","parameter":"contrast","value":-0.25}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .setEditParameter(assetId: expected, parameter: "contrast", value: -0.25))
    }

    func testResetEditParameterRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        for parameter in ["exposure", "contrast", "temperature", "saturation"] {
            let command = Command.resetEditParameter(assetId: id, parameter: parameter)
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(Command.self, from: data)
            XCTAssertEqual(command, decoded)
        }
    }

    func testDecodeResetEditParameterFromJSON() throws {
        let json = #"{"type":"resetEditParameter","assetId":"12345678-1234-1234-1234-123456789012","parameter":"exposure"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .resetEditParameter(assetId: expected, parameter: "exposure"))
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
        let command = Command.rotate(assetId: id, direction: "cw")
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","direction":"cw","type":"rotate"}"#
        )
    }

    func testRotateCCWJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.rotate(assetId: id, direction: "ccw")
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","direction":"ccw","type":"rotate"}"#
        )
    }

    func testGoBackJSON() throws {
        let command = Command.goBack
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"goBack"}"#)
    }

    /// Legacy JSON without a `direction` key must decode to `"cw"` for
    /// backwards compatibility with existing harness scripts.
    func testDecodeRotateWithoutDirectionDefaultsToCW() throws {
        let json = #"{"type":"rotate","assetId":"12345678-1234-1234-1234-123456789012"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .rotate(assetId: expected, direction: "cw"))
    }

    func testDecodeGoBackFromJSON() throws {
        let json = #"{"type":"goBack"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .goBack)
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
            #"{"assetCount":3,"downloadProgressByAssetId":{},"downloadingAssetIds":[],"hasUndoToast":false,"isZoomed":false,"minRating":3,"route":"library","scopeKind":"all","selectedAssetId":"12345678-1234-1234-1234-123456789012","selectedAssetIds":[],"showHistogram":true}"#
        )
    }

    func testAppStateJSONShapeWithoutSelection() throws {
        // Swift's default JSONEncoder omits nil optionals rather than
        // emitting them as `null`. Pin that shape so the harness wire
        // format is explicit about what consumers will see. `minRating`,
        // `isZoomed`, `scopeKind`, `selectedAssetIds`,
        // `hasUndoToast`, `downloadingAssetIds`,
        // `downloadProgressByAssetId`, and `showHistogram` are
        // non-optional and must always be present.
        let state = AppState(route: .library, assetCount: 0, selectedAssetId: nil)
        let data = try encoder.encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetCount":0,"downloadProgressByAssetId":{},"downloadingAssetIds":[],"hasUndoToast":false,"isZoomed":false,"minRating":0,"route":"library","scopeKind":"all","selectedAssetIds":[],"showHistogram":true}"#
        )
    }

    func testAppStateRoundTripWithIsZoomed() throws {
        let state = AppState(route: .loupe, isZoomed: true)
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
        XCTAssertTrue(decoded.isZoomed)
    }

    func testAppStateJSONShapeWithIsZoomedTrue() throws {
        let state = AppState(route: .loupe, isZoomed: true)
        let data = try encoder.encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetCount":0,"downloadProgressByAssetId":{},"downloadingAssetIds":[],"hasUndoToast":false,"isZoomed":true,"minRating":0,"route":"loupe","scopeKind":"all","selectedAssetIds":[],"showHistogram":true}"#
        )
    }

    func testAppStateRoundTripWithDownloadProgress() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let state = AppState(
            route: .loupe,
            selectedAssetId: id,
            downloadingAssetIds: [id],
            downloadProgressByAssetId: [id.uuidString: 0.42]
        )
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
        XCTAssertEqual(decoded.downloadingAssetIds, [id])
        XCTAssertEqual(decoded.downloadProgressByAssetId[id.uuidString], 0.42)
    }

    func testAppStateJSONShapeWithDownloadProgress() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let state = AppState(
            route: .loupe,
            selectedAssetId: id,
            downloadingAssetIds: [id],
            downloadProgressByAssetId: [id.uuidString: 0.5]
        )
        let data = try encoder.encode(state)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetCount":0,"downloadProgressByAssetId":{"12345678-1234-1234-1234-123456789012":0.5},"downloadingAssetIds":["12345678-1234-1234-1234-123456789012"],"hasUndoToast":false,"isZoomed":false,"minRating":0,"route":"loupe","scopeKind":"all","selectedAssetId":"12345678-1234-1234-1234-123456789012","selectedAssetIds":[],"showHistogram":true}"#
        )
    }

    func testAppStateRoundTripWithMultiSelection() throws {
        let a = UUID()
        let b = UUID()
        let state = AppState(
            route: .library,
            assetCount: 5,
            selectedAssetId: b,
            scopeKind: "recentlyDeleted",
            selectedAssetIds: [a, b],
            hasUndoToast: true
        )
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(AppState.self, from: data)
        XCTAssertEqual(state, decoded)
        XCTAssertEqual(decoded.scopeKind, "recentlyDeleted")
        XCTAssertEqual(Set(decoded.selectedAssetIds), [a, b])
        XCTAssertTrue(decoded.hasUndoToast)
    }

    // MARK: - selectNext / selectPrevious / zoomToggle / zoomReset

    func testSelectNextRoundTrip() throws {
        let command = Command.selectNext
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSelectNextJSON() throws {
        let command = Command.selectNext
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"selectNext"}"#)
    }

    func testDecodeSelectNextFromJSON() throws {
        let json = #"{"type":"selectNext"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .selectNext)
    }

    func testSelectPreviousRoundTrip() throws {
        let command = Command.selectPrevious
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSelectPreviousJSON() throws {
        let command = Command.selectPrevious
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"selectPrevious"}"#)
    }

    func testDecodeSelectPreviousFromJSON() throws {
        let json = #"{"type":"selectPrevious"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .selectPrevious)
    }

    func testSelectUpRoundTrip() throws {
        let command = Command.selectUp
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSelectUpJSON() throws {
        let command = Command.selectUp
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"selectUp"}"#)
    }

    func testDecodeSelectUpFromJSON() throws {
        let json = #"{"type":"selectUp"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .selectUp)
    }

    func testSelectDownRoundTrip() throws {
        let command = Command.selectDown
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSelectDownJSON() throws {
        let command = Command.selectDown
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"selectDown"}"#)
    }

    func testDecodeSelectDownFromJSON() throws {
        let json = #"{"type":"selectDown"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .selectDown)
    }

    func testZoomToggleRoundTrip() throws {
        let command = Command.zoomToggle
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testZoomToggleJSON() throws {
        let command = Command.zoomToggle
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"zoomToggle"}"#)
    }

    func testDecodeZoomToggleFromJSON() throws {
        let json = #"{"type":"zoomToggle"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .zoomToggle)
    }

    func testZoomResetRoundTrip() throws {
        let command = Command.zoomReset
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testExportRoundTrip() throws {
        let command = Command.export(
            destinationPath: "/tmp/export",
            format: "jpeg",
            applyEdits: true
        )
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testZoomResetJSON() throws {
        let command = Command.zoomReset
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"zoomReset"}"#)
    }

    func testExportJSON() throws {
        let command = Command.export(
            destinationPath: "/tmp/out",
            format: "tiff",
            applyEdits: false
        )
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"applyEdits":false,"destinationPath":"\/tmp\/out","format":"tiff","type":"export"}"#
        )
    }

    func testFetchOriginalRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.fetchOriginal(assetId: id)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testFetchOriginalJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.fetchOriginal(assetId: id)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","type":"fetchOriginal"}"#
        )
    }

    func testDecodeFetchOriginalFromJSON() throws {
        let json = #"{"type":"fetchOriginal","assetId":"12345678-1234-1234-1234-123456789012"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .fetchOriginal(assetId: expected))
    }

    func testDecodeZoomResetFromJSON() throws {
        let json = #"{"type":"zoomReset"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .zoomReset)
    }

    // MARK: - toggleHistogram

    func testToggleHistogramRoundTrip() throws {
        let command = Command.toggleHistogram
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testToggleHistogramJSON() throws {
        let command = Command.toggleHistogram
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"toggleHistogram"}"#)
    }

    func testDecodeToggleHistogramFromJSON() throws {
        let json = #"{"type":"toggleHistogram"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .toggleHistogram)
    }

    // MARK: - undo / redo

    func testUndoRoundTrip() throws {
        let command = Command.undo
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testUndoJSON() throws {
        let command = Command.undo
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"undo"}"#)
    }

    func testDecodeUndoFromJSON() throws {
        let json = #"{"type":"undo"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .undo)
    }

    func testRedoRoundTrip() throws {
        let command = Command.redo
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testRedoJSON() throws {
        let command = Command.redo
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"redo"}"#)
    }

    func testDecodeRedoFromJSON() throws {
        let json = #"{"type":"redo"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .redo)
    }

    // MARK: - Multi-select / delete commands

    func testSelectAssetsRoundTrip() throws {
        let ids = [UUID(), UUID(), UUID()]
        let command = Command.selectAssets(ids: ids)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testDeleteAssetsRoundTrip() throws {
        let command = Command.deleteAssets(ids: [UUID(), UUID()])
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testRestoreAssetsRoundTrip() throws {
        let command = Command.restoreAssets(ids: [UUID()])
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testPermanentlyDeleteAssetsRoundTrip() throws {
        let command = Command.permanentlyDeleteAssets(ids: [UUID(), UUID()])
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSetScopeRecentlyDeletedRoundTrip() throws {
        let command = Command.setScopeRecentlyDeleted
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testSetScopeRecentlyDeletedJSON() throws {
        let command = Command.setScopeRecentlyDeleted
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"setScopeRecentlyDeleted"}"#)
    }

    func testDeleteAssetsJSONShape() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let command = Command.deleteAssets(ids: [id])
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"ids":["11111111-2222-3333-4444-555555555555"],"type":"deleteAssets"}"#
        )
    }

    // MARK: - uploadToDrive

    func testUploadToDriveRoundTrip() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.uploadToDrive(assetId: id)
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testUploadToDriveJSON() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let command = Command.uploadToDrive(assetId: id)
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(
            json,
            #"{"assetId":"12345678-1234-1234-1234-123456789012","type":"uploadToDrive"}"#
        )
    }

    func testDecodeUploadToDriveFromJSON() throws {
        let json = #"{"type":"uploadToDrive","assetId":"12345678-1234-1234-1234-123456789012"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        let expected = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        XCTAssertEqual(command, .uploadToDrive(assetId: expected))
    }

    // MARK: - Drive auth commands

    func testConnectDriveRoundTrip() throws {
        let command = Command.connectDrive
        let data = try encoder.encode(command)
        let decoded = try decoder.decode(Command.self, from: data)
        XCTAssertEqual(command, decoded)
    }

    func testConnectDriveJSON() throws {
        let command = Command.connectDrive
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"connectDrive"}"#)
    }

    func testDisconnectDriveJSON() throws {
        let command = Command.disconnectDrive
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"disconnectDrive"}"#)
    }

    func testDriveAuthStateJSON() throws {
        let command = Command.driveAuthState
        let data = try encoder.encode(command)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertEqual(json, #"{"type":"driveAuthState"}"#)
    }

    func testDecodeDriveAuthStateFromJSON() throws {
        let json = #"{"type":"driveAuthState"}"#
        let command = try decoder.decode(Command.self, from: Data(json.utf8))
        XCTAssertEqual(command, .driveAuthState)
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
