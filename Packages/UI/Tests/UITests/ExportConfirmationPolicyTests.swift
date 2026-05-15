import Foundation
@testable import UI
import XCTest

final class ExportConfirmationPolicyTests: XCTestCase {

    // The one scenario that should prompt: blank intent against a full
    // library. No selection, no rating filter, All Photos scope, rows
    // present — dumping everything would be a surprise.
    func test_allScope_noSelection_noFilter_nonEmpty_prompts() {
        XCTAssertTrue(
            ExportConfirmationPolicy.shouldPrompt(
                scope: .all,
                minRating: 0,
                selectionEmpty: true,
                rowCount: 3
            )
        )
    }

    func test_selectionPresent_skipsPrompt() {
        XCTAssertFalse(
            ExportConfirmationPolicy.shouldPrompt(
                scope: .all,
                minRating: 0,
                selectionEmpty: false,
                rowCount: 3
            )
        )
    }

    func test_sessionScope_skipsPrompt() {
        XCTAssertFalse(
            ExportConfirmationPolicy.shouldPrompt(
                scope: .session(UUID()),
                minRating: 0,
                selectionEmpty: true,
                rowCount: 3
            )
        )
    }

    func test_recentlyDeletedScope_skipsPrompt() {
        XCTAssertFalse(
            ExportConfirmationPolicy.shouldPrompt(
                scope: .recentlyDeleted,
                minRating: 0,
                selectionEmpty: true,
                rowCount: 3
            )
        )
    }

    func test_ratingFilterActive_skipsPrompt() {
        XCTAssertFalse(
            ExportConfirmationPolicy.shouldPrompt(
                scope: .all,
                minRating: 3,
                selectionEmpty: true,
                rowCount: 3
            )
        )
    }

    func test_emptyLibrary_skipsPrompt() {
        XCTAssertFalse(
            ExportConfirmationPolicy.shouldPrompt(
                scope: .all,
                minRating: 0,
                selectionEmpty: true,
                rowCount: 0
            )
        )
    }
}
