import XCTest
@testable import DriveClient

final class DrivePathTests: XCTestCase {

    private func utcDate(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    func testSegmentsForDigitalAssetWithCaptureDate() {
        let captureDate = utcDate("2024-06-14T12:00:00Z")
        let importedDate = utcDate("2024-08-01T12:00:00Z")
        let segments = DrivePath.libraryFolderSegments(
            captureDate: captureDate,
            importedDate: importedDate,
            sourceType: .digital
        )
        XCTAssertEqual(segments, ["PhotoTool", "library", "2024", "2024-06-14", "digital"])
    }

    func testFallsBackToImportedDateWhenCaptureDateIsNil() {
        let importedDate = utcDate("2023-01-15T04:12:00Z")
        let segments = DrivePath.libraryFolderSegments(
            captureDate: nil,
            importedDate: importedDate,
            sourceType: .digital
        )
        XCTAssertEqual(segments[2], "2023")
        XCTAssertEqual(segments[3], "2023-01-15")
    }

    func testScanSourceTypeUsesScansFolder() {
        let date = utcDate("2025-03-22T08:00:00Z")
        let segments = DrivePath.libraryFolderSegments(
            captureDate: date,
            importedDate: date,
            sourceType: .scan
        )
        XCTAssertEqual(segments.last, "scans")
    }

    func testZeroPaddedMonthAndDay() {
        let date = utcDate("2024-01-05T00:00:00Z")
        let segments = DrivePath.libraryFolderSegments(
            captureDate: date,
            importedDate: date,
            sourceType: .digital
        )
        XCTAssertEqual(segments[3], "2024-01-05")
    }

    func testYearBoundaryDec31UTC() {
        let date = utcDate("2024-12-31T23:59:59Z")
        let segments = DrivePath.libraryFolderSegments(
            captureDate: date,
            importedDate: date,
            sourceType: .digital
        )
        XCTAssertEqual(segments[2], "2024")
        XCTAssertEqual(segments[3], "2024-12-31")
    }

    func testYearBoundaryJan1UTC() {
        let date = utcDate("2025-01-01T00:00:00Z")
        let segments = DrivePath.libraryFolderSegments(
            captureDate: date,
            importedDate: date,
            sourceType: .digital
        )
        XCTAssertEqual(segments[2], "2025")
        XCTAssertEqual(segments[3], "2025-01-01")
    }

    func testDisplayPathJoinsWithSlash() {
        let date = utcDate("2024-06-14T00:00:00Z")
        let path = DrivePath.displayPath(
            captureDate: date,
            importedDate: date,
            sourceType: .digital
        )
        XCTAssertEqual(path, "/PhotoTool/library/2024/2024-06-14/digital")
    }
}
