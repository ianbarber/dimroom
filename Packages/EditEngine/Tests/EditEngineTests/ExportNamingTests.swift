import XCTest
@testable import EditEngine

final class ExportNamingTests: XCTestCase {

    func testNoCollision() {
        let result = Exporter.collisionFreeName(
            baseName: "photo.jpg",
            existingNames: []
        )
        XCTAssertEqual(result, "photo.jpg")
    }

    func testSingleCollision() {
        let result = Exporter.collisionFreeName(
            baseName: "photo.jpg",
            existingNames: ["photo.jpg"]
        )
        XCTAssertEqual(result, "photo_1.jpg")
    }

    func testMultipleCollisions() {
        let result = Exporter.collisionFreeName(
            baseName: "photo.jpg",
            existingNames: ["photo.jpg", "photo_1.jpg", "photo_2.jpg"]
        )
        XCTAssertEqual(result, "photo_3.jpg")
    }

    func testNoExtension() {
        let result = Exporter.collisionFreeName(
            baseName: "README",
            existingNames: ["README"]
        )
        XCTAssertEqual(result, "README_1")
    }

    func testNoExtensionMultipleCollisions() {
        let result = Exporter.collisionFreeName(
            baseName: "README",
            existingNames: ["README", "README_1"]
        )
        XCTAssertEqual(result, "README_2")
    }

    func testDotfile() {
        let result = Exporter.collisionFreeName(
            baseName: ".hidden",
            existingNames: [".hidden"]
        )
        // NSString treats ".hidden" as no extension (pathExtension is ""),
        // so the stem is ".hidden" and we append the counter directly.
        XCTAssertEqual(result, ".hidden_1")
    }

    func testDifferentExtension() {
        let result = Exporter.collisionFreeName(
            baseName: "photo.tiff",
            existingNames: ["photo.jpg"]
        )
        XCTAssertEqual(result, "photo.tiff")
    }

    func testEmptyExistingNames() {
        let result = Exporter.collisionFreeName(
            baseName: "image.png",
            existingNames: Set()
        )
        XCTAssertEqual(result, "image.png")
    }
}
