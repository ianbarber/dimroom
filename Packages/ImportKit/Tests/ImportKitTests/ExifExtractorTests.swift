import XCTest
@testable import ImportKit

final class ExifExtractorTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExifExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testExtractsDateTimeOriginal() throws {
        let url = tmpDir.appendingPathComponent("dto.jpg")
        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:34:56"),
            to: url
        )

        let metadata = ExifExtractor.extract(from: url)
        XCTAssertNotNil(metadata.captureDate)

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: metadata.captureDate!
        )
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 12)
        XCTAssertEqual(components.minute, 34)
        XCTAssertEqual(components.second, 56)
    }

    func testExtractsMakeModelAsSourceDevice() throws {
        let url = tmpDir.appendingPathComponent("device.jpg")
        try TestFixtureBuilder.writeJPEG(
            exif: .init(make: "Canon", model: "Canon EOS R6"),
            to: url
        )

        let metadata = ExifExtractor.extract(from: url)
        // "Canon EOS R6" already starts with "Canon" so the join should
        // prefer the model alone rather than doubling the manufacturer.
        XCTAssertEqual(metadata.sourceDevice, "Canon EOS R6")
    }

    func testDistinctMakeModelJoinedWithSpace() throws {
        let url = tmpDir.appendingPathComponent("device2.jpg")
        try TestFixtureBuilder.writeJPEG(
            exif: .init(make: "Nikon", model: "D850"),
            to: url
        )

        let metadata = ExifExtractor.extract(from: url)
        XCTAssertEqual(metadata.sourceDevice, "Nikon D850")
    }

    func testWidthHeightPassThrough() throws {
        let url = tmpDir.appendingPathComponent("size.jpg")
        try TestFixtureBuilder.writeJPEG(
            width: 48,
            height: 32,
            exif: .init(),
            to: url
        )

        let metadata = ExifExtractor.extract(from: url)
        XCTAssertEqual(metadata.width, 48)
        XCTAssertEqual(metadata.height, 32)
    }

    func testOrientation6MapsTo90() throws {
        let url = tmpDir.appendingPathComponent("ori6.jpg")
        try TestFixtureBuilder.writeJPEG(
            exif: .init(orientation: 6),
            to: url
        )

        let metadata = ExifExtractor.extract(from: url)
        XCTAssertEqual(metadata.rotationDegrees, 90)
    }

    func testOrientation5MapsTo90DroppingMirror() throws {
        let url = tmpDir.appendingPathComponent("ori5.jpg")
        try TestFixtureBuilder.writeJPEG(
            exif: .init(orientation: 5),
            to: url
        )

        let metadata = ExifExtractor.extract(from: url)
        XCTAssertEqual(metadata.rotationDegrees, 90)
    }

    func testRotationDegreesMappingCoversAllEightOrientations() {
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 1), 0)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 2), 0)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 3), 180)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 4), 180)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 5), 90)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 6), 90)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 7), 270)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 8), 270)
        XCTAssertEqual(ExifExtractor.rotationDegrees(for: 99), 0)
    }

    func testMissingFileReturnsEmptyMetadata() {
        let url = tmpDir.appendingPathComponent("missing.jpg")
        let metadata = ExifExtractor.extract(from: url)
        XCTAssertNil(metadata.captureDate)
        XCTAssertNil(metadata.sourceDevice)
        XCTAssertEqual(metadata.width, 0)
        XCTAssertEqual(metadata.height, 0)
        XCTAssertEqual(metadata.rotationDegrees, 0)
    }

    func testJoinDeviceStringHandlesEmpties() {
        XCTAssertNil(ExifExtractor.joinDeviceString(make: nil, model: nil))
        XCTAssertNil(ExifExtractor.joinDeviceString(make: "", model: ""))
        XCTAssertEqual(
            ExifExtractor.joinDeviceString(make: "Canon", model: nil),
            "Canon"
        )
        XCTAssertEqual(
            ExifExtractor.joinDeviceString(make: nil, model: "EOS R6"),
            "EOS R6"
        )
    }
}
