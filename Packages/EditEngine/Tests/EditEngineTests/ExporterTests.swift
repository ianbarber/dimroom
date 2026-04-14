import Catalog
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EditEngine

final class ExporterTests: XCTestCase {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExporterTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Write a test JPEG to the temp directory and return its URL.
    private func makeSourceJPEG(name: String = "source.jpg") -> URL {
        let image = makeGradientImage(width: 32, height: 32)
        let sourceURL = tempDir.appendingPathComponent(name)
        let cgImage = context.createCGImage(image, from: image.extent)!
        let dest = CGImageDestinationCreateWithURL(
            sourceURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1, nil
        )!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return sourceURL
    }

    // MARK: - JPEG export

    func testJPEGExportWritesValidFile() throws {
        let sourceURL = makeSourceJPEG()
        let destURL = tempDir.appendingPathComponent("output.jpg")
        let config = ExportConfiguration(
            format: .jpeg,
            jpegQuality: 80,
            applyEdits: false,
            destinationURL: destURL
        )

        try Exporter.export(
            sourceURL: sourceURL,
            editState: nil,
            config: config,
            context: context
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        let data = try Data(contentsOf: destURL)
        // JPEG magic bytes: FF D8
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    // MARK: - TIFF export

    func testTIFFExportWritesValidFile() throws {
        let sourceURL = makeSourceJPEG()
        let destURL = tempDir.appendingPathComponent("output.tiff")
        let config = ExportConfiguration(
            format: .tiff,
            applyEdits: false,
            destinationURL: destURL
        )

        try Exporter.export(
            sourceURL: sourceURL,
            editState: nil,
            config: config,
            context: context
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        let data = try Data(contentsOf: destURL)
        // TIFF magic: 49 49 (little-endian) or 4D 4D (big-endian)
        let isTIFF = (data[0] == 0x49 && data[1] == 0x49) || (data[0] == 0x4D && data[1] == 0x4D)
        XCTAssertTrue(isTIFF, "Output should be a valid TIFF file")
    }

    // MARK: - Original format export

    func testOriginalExportCopiesFileByteForByte() throws {
        let sourceURL = makeSourceJPEG()
        let destURL = tempDir.appendingPathComponent("copy.jpg")
        let config = ExportConfiguration(
            format: .original,
            applyEdits: false,
            destinationURL: destURL
        )

        try Exporter.export(
            sourceURL: sourceURL,
            editState: nil,
            config: config,
            context: context
        )

        let sourceData = try Data(contentsOf: sourceURL)
        let destData = try Data(contentsOf: destURL)
        XCTAssertEqual(sourceData, destData)
    }

    // MARK: - Edit baking

    func testEditBakingProducesDifferentOutput() throws {
        let sourceURL = makeSourceJPEG()
        let uneditedURL = tempDir.appendingPathComponent("unedited.jpg")
        let editedURL = tempDir.appendingPathComponent("edited.jpg")

        // Export without edits
        try Exporter.export(
            sourceURL: sourceURL,
            editState: nil,
            config: ExportConfiguration(
                format: .jpeg, jpegQuality: 95, applyEdits: false, destinationURL: uneditedURL
            ),
            context: context
        )

        // Export with a visible edit (high exposure)
        let editState = EditState(exposure: 3.0)
        try Exporter.export(
            sourceURL: sourceURL,
            editState: editState,
            config: ExportConfiguration(
                format: .jpeg, jpegQuality: 95, applyEdits: true, destinationURL: editedURL
            ),
            context: context
        )

        let uneditedData = try Data(contentsOf: uneditedURL)
        let editedData = try Data(contentsOf: editedURL)
        XCTAssertNotEqual(uneditedData, editedData, "Edited export should differ from unedited")
    }

    func testNoEditStateExportsOriginalRegardlessOfToggle() throws {
        let sourceURL = makeSourceJPEG()
        let withToggleURL = tempDir.appendingPathComponent("with_toggle.jpg")
        let withoutToggleURL = tempDir.appendingPathComponent("without_toggle.jpg")

        // applyEdits=true but editState=nil → should behave same as applyEdits=false
        try Exporter.export(
            sourceURL: sourceURL,
            editState: nil,
            config: ExportConfiguration(
                format: .jpeg, jpegQuality: 95, applyEdits: true, destinationURL: withToggleURL
            ),
            context: context
        )
        try Exporter.export(
            sourceURL: sourceURL,
            editState: nil,
            config: ExportConfiguration(
                format: .jpeg, jpegQuality: 95, applyEdits: false, destinationURL: withoutToggleURL
            ),
            context: context
        )

        let withToggleData = try Data(contentsOf: withToggleURL)
        let withoutToggleData = try Data(contentsOf: withoutToggleURL)
        XCTAssertEqual(withToggleData, withoutToggleData)
    }

    // MARK: - Error handling

    func testUnreadableSourceThrows() {
        let bogusURL = tempDir.appendingPathComponent("nonexistent.jpg")
        let destURL = tempDir.appendingPathComponent("output.jpg")
        let config = ExportConfiguration(
            format: .jpeg, applyEdits: false, destinationURL: destURL
        )

        XCTAssertThrowsError(
            try Exporter.export(
                sourceURL: bogusURL,
                editState: nil,
                config: config,
                context: context
            )
        )
    }
}
