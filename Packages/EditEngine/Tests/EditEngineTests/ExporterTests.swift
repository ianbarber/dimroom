import Catalog
import CoreGraphics
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

    /// Write a lossless TIFF of the given pixel dimensions and return its
    /// URL. Used by the crop-resolution tests where the exported pixel
    /// dimensions are asserted exactly.
    private func makeSourceTIFF(width: Int, height: Int, name: String = "source.tiff") -> URL {
        let image = makeGradientImage(width: width, height: height)
        let sourceURL = tempDir.appendingPathComponent(name)
        let cgImage = context.createCGImage(image, from: image.extent)!
        let dest = CGImageDestinationCreateWithURL(
            sourceURL as CFURL,
            UTType.tiff.identifier as CFString,
            1, nil
        )!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return sourceURL
    }

    /// Pixel dimensions of an image file on disk.
    private func pixelSize(of url: URL) throws -> CGSize {
        guard let image = CIImage(contentsOf: url) else {
            throw ExportError.unreadableSource(url)
        }
        return image.extent.size
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

    // MARK: - Crop resolution (#320)

    /// A crop authored against the ~2048px preview must export at the
    /// full-resolution original's framing, not a tiny corner ROI. Here a
    /// left-half crop authored against a 64² reference is exported from a
    /// 256² original — the output must be 128×256 (½ width, full height of
    /// 256), not 32×64 (the corrupt corner crop that the pre-#320 factor-1.0
    /// path would produce).
    func testCroppedExportScalesToFullResolution() throws {
        let sourceURL = makeSourceTIFF(width: 256, height: 256)
        let destURL = tempDir.appendingPathComponent("cropped.tiff")

        // Display-space left half → CI pixel against the 64² reference =
        // (x: 0, y: 0, w: 32, h: 64).
        let reference = CGSize(width: 64, height: 64)
        let display = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
        let cropRect = CropGeometry.normalizedTopLeftToCIPixel(
            rect: display,
            imageSize: reference
        )
        let editState = EditState(cropRect: cropRect, cropReferenceSize: reference)

        try Exporter.export(
            sourceURL: sourceURL,
            editState: editState,
            config: ExportConfiguration(
                format: .tiff, applyEdits: true, destinationURL: destURL
            ),
            context: context
        )

        let size = try pixelSize(of: destURL)
        XCTAssertEqual(size.width, 128, accuracy: 1.0,
                       "expected ½ of the 256px original, got \(size.width)")
        XCTAssertEqual(size.height, 256, accuracy: 1.0,
                       "expected the full 256px height, got \(size.height)")
        // Explicitly assert we did not regress to the corner-crop bug,
        // which would size the export against the 64px reference.
        XCTAssertGreaterThan(size.width, 64,
                             "export collapsed to the preview-pixel corner crop (#320)")
    }

    /// An uncropped export must cover the full original frame (acceptance
    /// criterion 2). A non-crop edit is applied so `applyEdits` actually
    /// routes through the renderer.
    func testUncroppedExportCoversFullFrame() throws {
        let sourceURL = makeSourceTIFF(width: 256, height: 256)
        let destURL = tempDir.appendingPathComponent("uncropped.tiff")
        let editState = EditState(exposure: 0.5)

        try Exporter.export(
            sourceURL: sourceURL,
            editState: editState,
            config: ExportConfiguration(
                format: .tiff, applyEdits: true, destinationURL: destURL
            ),
            context: context
        )

        let size = try pixelSize(of: destURL)
        XCTAssertEqual(size.width, 256, accuracy: 1.0)
        XCTAssertEqual(size.height, 256, accuracy: 1.0)
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
