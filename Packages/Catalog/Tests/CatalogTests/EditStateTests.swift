import CoreGraphics
import XCTest
@testable import Catalog

final class EditStateTests: XCTestCase {

    private func makeDatabase() throws -> CatalogDatabase {
        try CatalogDatabase.inMemory()
    }

    private func makeSampleAsset(contentHash: String = "abc123") -> Asset {
        Asset(
            contentHash: contentHash,
            originalFilename: "IMG_0001.CR3",
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceType: .digital,
            width: 6000,
            height: 4000,
            rawFormat: "CR3",
            bytes: 25_000_000
        )
    }

    // MARK: - EditState Model

    func testDefaultEditStateIsIdentity() {
        let state = EditState()
        XCTAssertEqual(state.exposure, 0)
        XCTAssertEqual(state.contrast, 0)
        XCTAssertEqual(state.highlights, 0)
        XCTAssertEqual(state.shadows, 0)
        XCTAssertEqual(state.whites, 0)
        XCTAssertEqual(state.blacks, 0)
        XCTAssertEqual(state.temperature, 6500)
        XCTAssertEqual(state.tint, 0)
        XCTAssertEqual(state.clarity, 0)
        XCTAssertEqual(state.sharpening, 0)
        XCTAssertEqual(state.vibrance, 0)
        XCTAssertEqual(state.saturation, 0)
        XCTAssertEqual(state.luminanceNoiseReduction, 0)
        XCTAssertEqual(state.chrominanceNoiseReduction, 0)
        XCTAssertEqual(state.vignetteAmount, 0)
        XCTAssertEqual(state.vignetteRoundness, 50)
        XCTAssertEqual(state.vignetteSoftness, 50)
        XCTAssertEqual(state.splitToneHighlightHue, 0)
        XCTAssertEqual(state.splitToneHighlightSaturation, 0)
        XCTAssertEqual(state.splitToneShadowHue, 0)
        XCTAssertEqual(state.splitToneShadowSaturation, 0)
        XCTAssertEqual(state.splitToneBalance, 0)
        XCTAssertEqual(state.hueShift, EditState.hslIdentity)
        XCTAssertEqual(state.hslSaturation, EditState.hslIdentity)
        XCTAssertEqual(state.hslLuminance, EditState.hslIdentity)
        XCTAssertEqual(state.hueShift.count, 8)
        XCTAssertEqual(state.toneCurvePoints, EditState.identityCurve)
        XCTAssertEqual(state.redCurvePoints, EditState.identityCurve)
        XCTAssertEqual(state.greenCurvePoints, EditState.identityCurve)
        XCTAssertEqual(state.blueCurvePoints, EditState.identityCurve)
        XCTAssertEqual(state.perspectiveVertical, 0)
        XCTAssertEqual(state.perspectiveHorizontal, 0)
        XCTAssertEqual(state.perspectiveRotation, 0)
        XCTAssertFalse(state.chromaticAberration)
        XCTAssertFalse(state.lensVignette)
        XCTAssertNil(state.cropRect)
        XCTAssertNil(state.cropAngle)
    }

    func testIdentityCurveConstant() {
        XCTAssertEqual(EditState.identityCurve, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
    }

    func testCurveJSONRoundTrip() throws {
        let sCurve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.15),
            CGPoint(x: 0.75, y: 0.85),
            CGPoint(x: 1, y: 1)
        ]
        let state = EditState(
            toneCurvePoints: sCurve,
            redCurvePoints: [CGPoint(x: 0, y: 0.05), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 1, y: 1)],
            greenCurvePoints: EditState.identityCurve,
            blueCurvePoints: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.92)]
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(decoded.toneCurvePoints, sCurve)
        XCTAssertEqual(decoded.redCurvePoints, state.redCurvePoints)
        XCTAssertEqual(decoded.greenCurvePoints, EditState.identityCurve)
        XCTAssertEqual(decoded.blueCurvePoints, state.blueCurvePoints)
        XCTAssertEqual(decoded, state)
    }

    func testLegacyEditStateJSONDecodesCurvesToIdentity() throws {
        // A pre-existing catalog row written before curve fields existed.
        // Decoder must fall back to identity curve arrays without throwing.
        let legacy = """
        {
            "exposure": 0.5,
            "contrast": 10,
            "highlights": 0,
            "shadows": 0,
            "whites": 0,
            "blacks": 0,
            "temperature": 6500,
            "tint": 0,
            "clarity": 0,
            "sharpening": 0,
            "vibrance": 0,
            "saturation": 0,
            "vignetteAmount": 0,
            "vignetteRoundness": 50,
            "vignetteSoftness": 50
        }
        """

        let decoded = try JSONDecoder().decode(EditState.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.toneCurvePoints, EditState.identityCurve)
        XCTAssertEqual(decoded.redCurvePoints, EditState.identityCurve)
        XCTAssertEqual(decoded.greenCurvePoints, EditState.identityCurve)
        XCTAssertEqual(decoded.blueCurvePoints, EditState.identityCurve)
    }

    func testEditStateJSONRoundTrip() throws {
        let state = EditState(
            exposure: 1.5,
            contrast: 20,
            highlights: -30,
            shadows: 40,
            whites: -10,
            blacks: 15,
            temperature: 5200,
            tint: -8,
            clarity: 25,
            sharpening: 65,
            vibrance: 10,
            saturation: -5,
            luminanceNoiseReduction: 35,
            chrominanceNoiseReduction: 55,
            splitToneHighlightHue: 30,
            splitToneHighlightSaturation: 40,
            splitToneShadowHue: 210,
            splitToneShadowSaturation: 30,
            splitToneBalance: 20,
            vignetteAmount: -40,
            vignetteRoundness: 70,
            vignetteSoftness: 30,
            hueShift: [12, -8, 0, 25, 0, -40, 6, 0],
            hslSaturation: [0, 50, 0, 0, -30, 0, 0, 20],
            hslLuminance: [-10, 0, 0, 15, 0, 0, 0, 0],
            perspectiveVertical: 35,
            perspectiveHorizontal: -22,
            perspectiveRotation: 4.5,
            chromaticAberration: true,
            lensVignette: true,
            cropRect: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5),
            cropAngle: 2.5
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(state, decoded)
    }

    func testLegacyEditStateJSONDecodesWithDefaults() throws {
        // A pre-existing catalog row written before sharpening/vignette/HSL
        // fields existed. The new keys are absent; decoder must fall back to
        // identity defaults without throwing.
        let legacy = """
        {
            "exposure": 1.5,
            "contrast": 20,
            "highlights": 0,
            "shadows": 0,
            "whites": 0,
            "blacks": 0,
            "temperature": 6500,
            "tint": 0,
            "clarity": 10,
            "vibrance": 0,
            "saturation": 0
        }
        """

        let decoded = try JSONDecoder().decode(EditState.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.exposure, 1.5)
        XCTAssertEqual(decoded.contrast, 20)
        XCTAssertEqual(decoded.clarity, 10)
        XCTAssertEqual(decoded.sharpening, 0)
        XCTAssertEqual(decoded.luminanceNoiseReduction, 0)
        XCTAssertEqual(decoded.chrominanceNoiseReduction, 0)
        XCTAssertEqual(decoded.vignetteAmount, 0)
        XCTAssertEqual(decoded.vignetteRoundness, 50)
        XCTAssertEqual(decoded.vignetteSoftness, 50)
        XCTAssertEqual(decoded.splitToneHighlightHue, 0)
        XCTAssertEqual(decoded.splitToneHighlightSaturation, 0)
        XCTAssertEqual(decoded.splitToneShadowHue, 0)
        XCTAssertEqual(decoded.splitToneShadowSaturation, 0)
        XCTAssertEqual(decoded.splitToneBalance, 0)
        XCTAssertEqual(decoded.hueShift, EditState.hslIdentity)
        XCTAssertEqual(decoded.hslSaturation, EditState.hslIdentity)
        XCTAssertEqual(decoded.hslLuminance, EditState.hslIdentity)
        XCTAssertEqual(decoded.perspectiveVertical, 0)
        XCTAssertEqual(decoded.perspectiveHorizontal, 0)
        XCTAssertEqual(decoded.perspectiveRotation, 0)
        XCTAssertFalse(decoded.chromaticAberration)
        XCTAssertFalse(decoded.lensVignette)
    }

    func testHSLLengthMismatchPadsToEight() throws {
        let json = """
        {
            "hueShift": [10, 20, 30]
        }
        """
        let decoded = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hueShift, [10, 20, 30, 0, 0, 0, 0, 0])
        XCTAssertEqual(decoded.hslSaturation, EditState.hslIdentity)
    }

    func testIdentityEditStateRoundTrip() throws {
        let state = EditState()

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)

        XCTAssertEqual(state, decoded)
    }

    func testSortedKeysEncoding() throws {
        let state = EditState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(state)
        let json = String(data: data, encoding: .utf8)!

        // Keys should be alphabetically ordered
        let keys = ["blacks", "blueCurvePoints", "chromaticAberration", "chrominanceNoiseReduction",
                     "clarity", "contrast", "exposure", "greenCurvePoints", "highlights",
                     "hslLuminance", "hslSaturation", "hueShift", "lensVignette",
                     "luminanceNoiseReduction",
                     "perspectiveHorizontal", "perspectiveRotation", "perspectiveVertical",
                     "redCurvePoints", "saturation", "shadows", "sharpening",
                     "splitToneBalance", "splitToneHighlightHue",
                     "splitToneHighlightSaturation", "splitToneShadowHue",
                     "splitToneShadowSaturation",
                     "temperature", "tint", "toneCurvePoints",
                     "vibrance", "vignetteAmount", "vignetteRoundness",
                     "vignetteSoftness", "whites"]
        var lastIndex = json.startIndex
        for key in keys {
            guard let range = json.range(of: "\"\(key)\"", range: lastIndex..<json.endIndex) else {
                XCTFail("Key \(key) not found after previous key")
                return
            }
            lastIndex = range.upperBound
        }
    }

    // MARK: - Database Operations

    func testSaveAndLoadEditState() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        let state = EditState(exposure: 1.0, contrast: 10)
        try db.saveEditState(state, for: asset.id)

        let loaded = try db.latestEditState(for: asset.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded, state)
    }

    func testVersionAutoIncrements() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        let v1 = try db.saveEditState(EditState(exposure: 1.0), for: asset.id)
        let v2 = try db.saveEditState(EditState(exposure: 2.0), for: asset.id)

        XCTAssertEqual(v1, 1)
        XCTAssertEqual(v2, 2)
    }

    func testLatestReturnsNilForNoEdits() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        let result = try db.latestEditState(for: asset.id)
        XCTAssertNil(result)
    }

    func testEditHistoryOrderedNewestFirst() throws {
        let db = try makeDatabase()
        let asset = makeSampleAsset()
        try db.insertAsset(asset)

        try db.saveEditState(EditState(exposure: 1.0), for: asset.id)
        try db.saveEditState(EditState(exposure: 2.0), for: asset.id)
        try db.saveEditState(EditState(exposure: 3.0), for: asset.id)

        let history = try db.editHistory(for: asset.id)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].version, 3)
        XCTAssertEqual(history[1].version, 2)
        XCTAssertEqual(history[2].version, 1)
        XCTAssertEqual(history[0].state.exposure, 3.0)
        XCTAssertEqual(history[1].state.exposure, 2.0)
        XCTAssertEqual(history[2].state.exposure, 1.0)
    }

    func testMultipleAssetsIndependent() throws {
        let db = try makeDatabase()
        let asset1 = makeSampleAsset(contentHash: "hash1")
        let asset2 = makeSampleAsset(contentHash: "hash2")
        try db.insertAsset(asset1)
        try db.insertAsset(asset2)

        let v1 = try db.saveEditState(EditState(exposure: 1.0), for: asset1.id)
        let v2 = try db.saveEditState(EditState(exposure: 2.0), for: asset2.id)

        XCTAssertEqual(v1, 1)
        XCTAssertEqual(v2, 1)

        let state1 = try db.latestEditState(for: asset1.id)
        let state2 = try db.latestEditState(for: asset2.id)
        XCTAssertEqual(state1?.exposure, 1.0)
        XCTAssertEqual(state2?.exposure, 2.0)
    }
}
