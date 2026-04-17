import Catalog
import Foundation
import XCTest
@testable import UI

final class ExportScopeTests: XCTestCase {

    func test_emptySelection_returnsAllVisibleRows() {
        let rows = makeRows(count: 3)

        let result = ExportScope.resolve(selectedIds: [], rows: rows)

        XCTAssertEqual(result.map(\.id), rows.map(\.id))
    }

    func test_singleSelectionPresentInRows_returnsJustThatAsset() {
        let rows = makeRows(count: 3)
        let target = rows[1]

        let result = ExportScope.resolve(
            selectedIds: [target.id],
            rows: rows
        )

        XCTAssertEqual(result.map(\.id), [target.id])
    }

    func test_multipleSelection_returnsMatchedRowsInRowOrder() {
        let rows = makeRows(count: 4)
        // Pass selection out of order; output should follow the row order,
        // not the iteration order of the set, so exports land in the same
        // sequence the user sees in the grid.
        let selection: Set<UUID> = [rows[2].id, rows[0].id]

        let result = ExportScope.resolve(
            selectedIds: selection,
            rows: rows
        )

        XCTAssertEqual(result.map(\.id), [rows[0].id, rows[2].id])
    }

    func test_staleSelectionNotInRows_fallsBackToAllVisible() {
        let rows = makeRows(count: 2)
        let orphan = UUID()

        let result = ExportScope.resolve(
            selectedIds: [orphan],
            rows: rows
        )

        XCTAssertEqual(result.map(\.id), rows.map(\.id))
    }

    func test_emptyRowsWithSelection_returnsEmpty() {
        let result = ExportScope.resolve(
            selectedIds: [UUID()],
            rows: []
        )

        XCTAssertTrue(result.isEmpty)
    }

    func test_emptyRowsNoSelection_returnsEmpty() {
        let result = ExportScope.resolve(selectedIds: [], rows: [])

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Helpers

    private func makeRows(count: Int) -> [LibraryRow] {
        (0..<count).map { index in
            let asset = TestFixtures.makeAsset(
                hash: String(repeating: "a", count: 63) + "\(index)",
                filename: "photo-\(index).jpg"
            )
            return LibraryRow(asset: asset, thumbnailURL: nil, previewURL: nil)
        }
    }
}
