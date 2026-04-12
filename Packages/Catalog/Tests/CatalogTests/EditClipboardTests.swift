import CoreGraphics
import XCTest
@testable import Catalog

final class EditClipboardTests: XCTestCase {

    func testCopyStoresState() {
        let clipboard = EditClipboard()
        let state = EditState(exposure: 1.5, contrast: 0.3)
        let assetId = UUID()

        XCTAssertTrue(clipboard.isEmpty)
        clipboard.copy(state, from: assetId)
        XCTAssertFalse(clipboard.isEmpty)
        XCTAssertEqual(clipboard.copiedState, state)
        XCTAssertEqual(clipboard.sourceAssetId, assetId)
    }

    func testPasteExcludingCropStripsCropFields() {
        let clipboard = EditClipboard()
        let state = EditState(
            exposure: 2.0,
            contrast: 0.5,
            highlights: -0.3,
            cropRect: CGRect(x: 10, y: 20, width: 100, height: 200),
            cropAngle: 15.0
        )
        clipboard.copy(state, from: UUID())

        let pasted = clipboard.pasteExcludingCrop()
        XCTAssertNotNil(pasted)
        XCTAssertEqual(pasted!.exposure, 2.0)
        XCTAssertEqual(pasted!.contrast, 0.5)
        XCTAssertEqual(pasted!.highlights, -0.3)
        XCTAssertNil(pasted!.cropRect)
        XCTAssertNil(pasted!.cropAngle)
    }

    func testPasteIncludingCropPreservesAll() {
        let clipboard = EditClipboard()
        let cropRect = CGRect(x: 10, y: 20, width: 100, height: 200)
        let state = EditState(
            exposure: 2.0,
            contrast: 0.5,
            cropRect: cropRect,
            cropAngle: 15.0
        )
        clipboard.copy(state, from: UUID())

        let pasted = clipboard.pasteIncludingCrop()
        XCTAssertNotNil(pasted)
        XCTAssertEqual(pasted!, state)
        XCTAssertEqual(pasted!.cropRect, cropRect)
        XCTAssertEqual(pasted!.cropAngle, 15.0)
    }

    func testPasteWhenEmptyReturnsNil() {
        let clipboard = EditClipboard()

        XCTAssertNil(clipboard.pasteExcludingCrop())
        XCTAssertNil(clipboard.pasteIncludingCrop())
    }

    func testCopyIdentityState() {
        let clipboard = EditClipboard()
        let identity = EditState()
        clipboard.copy(identity, from: UUID())

        let pasted = clipboard.pasteExcludingCrop()
        XCTAssertNotNil(pasted)
        XCTAssertEqual(pasted!, identity)
    }

    func testCopyOverwritesPrevious() {
        let clipboard = EditClipboard()
        let stateA = EditState(exposure: 1.0)
        let stateB = EditState(exposure: 2.0)
        let idA = UUID()
        let idB = UUID()

        clipboard.copy(stateA, from: idA)
        XCTAssertEqual(clipboard.copiedState, stateA)
        XCTAssertEqual(clipboard.sourceAssetId, idA)

        clipboard.copy(stateB, from: idB)
        XCTAssertEqual(clipboard.copiedState, stateB)
        XCTAssertEqual(clipboard.sourceAssetId, idB)

        let pasted = clipboard.pasteExcludingCrop()
        XCTAssertEqual(pasted!.exposure, 2.0)
    }
}
