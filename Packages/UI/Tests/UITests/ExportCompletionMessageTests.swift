import Foundation
@testable import UI
import XCTest

final class ExportCompletionMessageTests: XCTestCase {

    func test_allSucceeded_singular() {
        let m = ExportCompletionMessage.forCompletion(exported: 1, skipped: 0, failures: [])
        XCTAssertEqual(m.title, "Export complete")
        XCTAssertEqual(m.body, "Exported 1 photo.")
    }

    func test_allSucceeded_plural() {
        let m = ExportCompletionMessage.forCompletion(exported: 5, skipped: 0, failures: [])
        XCTAssertEqual(m.title, "Export complete")
        XCTAssertEqual(m.body, "Exported 5 photos.")
    }

    func test_partial_listsReasons() {
        let m = ExportCompletionMessage.forCompletion(
            exported: 2,
            skipped: 1,
            failures: ["IMG_0003.jpg: no local copy available"]
        )
        XCTAssertEqual(m.title, "Export finished with issues")
        XCTAssertTrue(m.body.contains("Exported 2 of 3"))
        XCTAssertTrue(m.body.contains("1 photo was skipped"))
        XCTAssertTrue(m.body.contains("IMG_0003.jpg"))
    }

    func test_allSkipped_titleSwitchesToFailed() {
        let m = ExportCompletionMessage.forCompletion(
            exported: 0,
            skipped: 2,
            failures: ["A.jpg: x", "B.jpg: y"]
        )
        XCTAssertEqual(m.title, "Export failed")
        XCTAssertTrue(m.body.contains("No photos were exported"))
        XCTAssertTrue(m.body.contains("A.jpg"))
        XCTAssertTrue(m.body.contains("B.jpg"))
    }

    func test_failuresTruncatedAtThree() {
        let m = ExportCompletionMessage.forCompletion(
            exported: 1,
            skipped: 5,
            failures: ["A", "B", "C", "D", "E"]
        )
        // First three are listed, the remaining two fold into a tail.
        XCTAssertTrue(m.body.contains("A"))
        XCTAssertTrue(m.body.contains("B"))
        XCTAssertTrue(m.body.contains("C"))
        XCTAssertTrue(m.body.contains("…and 2 more"))
        XCTAssertFalse(m.body.contains("\nD"))
    }
}
