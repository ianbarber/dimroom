import Catalog
import XCTest
@testable import ImportKit

final class FolderImporterTests: XCTestCase {
    private var tmpRoot: URL!
    private var sourceDir: URL!
    private var originalsDir: URL!
    private var catalog: CatalogDatabase!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderImporterTests-\(UUID().uuidString)")
        sourceDir = tmpRoot.appendingPathComponent("source")
        originalsDir = tmpRoot.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        catalog = try CatalogDatabase.inMemory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - Happy path

    func testHappyPathImportsSupportedFilesAndIgnoresEverythingElse() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        let jpeg1 = sourceDir.appendingPathComponent("IMG_0001.jpg")
        let jpeg2 = sourceDir.appendingPathComponent("IMG_0002.JPEG")
        let readme = sourceDir.appendingPathComponent("readme.txt")
        let dsStore = sourceDir.appendingPathComponent(".DS_Store")
        let dotHidden = sourceDir.appendingPathComponent(".hidden.jpg")

        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:34:56", make: "Canon", model: "Canon EOS R6"),
            to: jpeg1
        )
        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:35:00"),
            to: jpeg2
        )
        try Data("not an image".utf8).write(to: readme)
        try Data([0x00]).write(to: dsStore)
        try TestFixtureBuilder.writeJPEG(exif: .init(), to: dotHidden)

        let result = try await importer.importFolder(sourceDir)

        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)

        let assets = try catalog.fetchAssets()
        XCTAssertEqual(assets.count, 2)

        let filenames = Set(assets.map(\.originalFilename))
        XCTAssertEqual(filenames, ["IMG_0001.jpg", "IMG_0002.JPEG"])

        // All imported assets must be .digital.
        XCTAssertTrue(assets.allSatisfy { $0.sourceType == .digital })
        // All JPEG assets must have rawFormat == nil.
        XCTAssertTrue(assets.allSatisfy { $0.rawFormat == nil })
    }

    // MARK: - Asset metadata

    func testAssetCapturesExifAndSizeFields() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        let url = sourceDir.appendingPathComponent("canon.jpg")
        try TestFixtureBuilder.writeJPEG(
            width: 48,
            height: 32,
            exif: .init(
                dateTimeOriginal: "2024:06:01 12:34:56",
                make: "Canon",
                model: "Canon EOS R6",
                orientation: 6
            ),
            to: url
        )

        _ = try await importer.importFolder(sourceDir)

        let assets = try catalog.fetchAssets()
        XCTAssertEqual(assets.count, 1)
        let asset = assets[0]
        XCTAssertEqual(asset.sourceDevice, "Canon EOS R6")
        XCTAssertEqual(asset.width, 48)
        XCTAssertEqual(asset.height, 32)
        XCTAssertEqual(asset.rotation, 90)
        XCTAssertNotNil(asset.captureDate)
        XCTAssertGreaterThan(asset.bytes, 0)
    }

    // MARK: - Copy not move

    func testOriginalIsCopiedNotMoved() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        let url = sourceDir.appendingPathComponent("keep.jpg")
        try TestFixtureBuilder.writeJPEG(exif: .init(), to: url)

        _ = try await importer.importFolder(sourceDir)

        // Original at the source path must still exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Asset.localPath must point somewhere under the originals dir.
        let asset = try XCTUnwrap(try catalog.fetchAssets().first)
        let localPath = try XCTUnwrap(asset.localPath)
        XCTAssertTrue(
            localPath.hasPrefix(originalsDir.path),
            "expected \(localPath) to be under \(originalsDir.path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
    }

    // MARK: - Idempotency / dedup

    func testRerunningImportIsIdempotent() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:34:56"),
            to: sourceDir.appendingPathComponent("a.jpg")
        )
        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:35:00"),
            to: sourceDir.appendingPathComponent("b.jpg")
        )

        let first = try await importer.importFolder(sourceDir)
        XCTAssertEqual(first.importedCount, 2)
        XCTAssertEqual(first.skippedCount, 0)

        let second = try await importer.importFolder(sourceDir)
        XCTAssertEqual(second.importedCount, 0)
        XCTAssertEqual(second.skippedCount, 2)

        // Catalog still has exactly two assets.
        XCTAssertEqual(try catalog.fetchAssets().count, 2)
    }

    // MARK: - RAW extension

    func testRawExtensionSetsRawFormat() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        // Write a .dng with JPEG bytes — we only branch on extension for
        // rawFormat, not on decoding the file.
        let jpegBytes = try jpegBytes(
            exif: .init(dateTimeOriginal: "2024:06:01 12:34:56")
        )
        let dng = sourceDir.appendingPathComponent("RAW_0001.DNG")
        try jpegBytes.write(to: dng)

        try TestFixtureBuilder.writeJPEG(
            exif: .init(),
            to: sourceDir.appendingPathComponent("plain.jpg")
        )

        let result = try await importer.importFolder(sourceDir)
        XCTAssertEqual(result.importedCount, 2)

        let assets = try catalog.fetchAssets()
        let byName = Dictionary(uniqueKeysWithValues: assets.map { ($0.originalFilename, $0) })
        XCTAssertEqual(byName["RAW_0001.DNG"]?.rawFormat, "dng")
        XCTAssertNil(byName["plain.jpg"]?.rawFormat)
    }

    // MARK: - Recursive walk

    func testRecursivelyWalksSubdirectories() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        let sub = sourceDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:34:56"),
            to: sourceDir.appendingPathComponent("top.jpg")
        )
        try TestFixtureBuilder.writeJPEG(
            exif: .init(dateTimeOriginal: "2024:06:01 12:35:00"),
            to: sub.appendingPathComponent("nested.jpg")
        )

        let result = try await importer.importFolder(sourceDir)
        XCTAssertEqual(result.importedCount, 2)
    }

    // MARK: - ImportSession

    func testCreatesSingleImportSessionPerCall() async throws {
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)

        try TestFixtureBuilder.writeJPEG(
            exif: .init(),
            to: sourceDir.appendingPathComponent("a.jpg")
        )

        let first = try await importer.importFolder(sourceDir)
        let second = try await importer.importFolder(sourceDir)
        XCTAssertNotEqual(first.sessionId, second.sessionId)
    }

    // MARK: - Helpers

    /// Produces the raw bytes of a tiny JPEG with the given EXIF properties,
    /// without writing it to a named destination. Used for RAW-extension tests
    /// where the file extension lies about its contents.
    private func jpegBytes(exif: TestFixtureBuilder.ExifOptions) throws -> Data {
        let scratch = tmpRoot.appendingPathComponent("scratch-\(UUID().uuidString).jpg")
        try TestFixtureBuilder.writeJPEG(exif: exif, to: scratch)
        let data = try Data(contentsOf: scratch)
        try? FileManager.default.removeItem(at: scratch)
        return data
    }
}
