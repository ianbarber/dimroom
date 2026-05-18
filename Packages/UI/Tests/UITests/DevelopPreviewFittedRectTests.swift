import CoreGraphics
import Foundation
@testable import UI
import XCTest

/// Regression for issue #239 bugs 1 & 3: the crop overlay must be anchored
/// to the same letterboxed image rect that `aspectRatio(.fit)` would
/// produce, so normalised crop coordinates map onto the visible pixels.
/// `DevelopView.fittedRect(frame:sourceAspect:)` is the geometry helper
/// that drives that anchoring.
final class DevelopPreviewFittedRectTests: XCTestCase {

    func testFittedRectForSquareSourceInWideFrameLetterboxesHorizontally() {
        let frame = CGSize(width: 1000, height: 500)
        let rect = DevelopView.fittedRect(frame: frame, sourceAspect: 1.0)
        XCTAssertEqual(rect.width, 500, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 500, accuracy: 1e-6)
        XCTAssertEqual(rect.midX, frame.width / 2, accuracy: 1e-6)
        XCTAssertEqual(rect.midY, frame.height / 2, accuracy: 1e-6)
    }

    func testFittedRectForLandscapeSourceInSquareFrameLetterboxesVertically() {
        let frame = CGSize(width: 600, height: 600)
        let rect = DevelopView.fittedRect(frame: frame, sourceAspect: 3.0 / 2.0)
        XCTAssertEqual(rect.width, 600, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 400, accuracy: 1e-6)
        XCTAssertEqual(rect.minY, 100, accuracy: 1e-6)
    }

    func testFittedRectForPortraitSourceInLandscapeFrameLetterboxesHorizontally() {
        let frame = CGSize(width: 1200, height: 800)
        let rect = DevelopView.fittedRect(frame: frame, sourceAspect: 2.0 / 3.0)
        XCTAssertEqual(rect.height, 800, accuracy: 1e-6)
        XCTAssertEqual(rect.width, 800 * 2.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(rect.midX, frame.width / 2, accuracy: 1e-6)
    }

    /// When the source aspect exactly matches the frame the rect fills
    /// the frame with no letterbox bands.
    func testFittedRectFillsFrameWhenAspectsMatch() {
        let frame = CGSize(width: 900, height: 600)
        let rect = DevelopView.fittedRect(frame: frame, sourceAspect: 1.5)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: frame))
    }

    func testFittedRectHandlesDegenerateInputs() {
        let zeroFrame = DevelopView.fittedRect(frame: .zero, sourceAspect: 1.0)
        XCTAssertEqual(zeroFrame, .zero)

        let zeroAspect = DevelopView.fittedRect(
            frame: CGSize(width: 100, height: 100),
            sourceAspect: 0
        )
        XCTAssertEqual(zeroAspect, CGRect(x: 0, y: 0, width: 100, height: 100))
    }
}
