import Catalog
import CoreGraphics
import Foundation
import ImageIO
import ImportKit
import Previews
import UniformTypeIdentifiers
@testable import UI
import XCTest

final class ImportCoordinatorTests: XCTestCase {
    private var tmpRoot: URL!
    private var sourceDir: URL!
    private var originalsDir: URL!
    private var previewCacheDir: URL!
    private var catalog: CatalogDatabase!

    override func setUp() async throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportCoordinatorTests-\(UUID().uuidString)")
        sourceDir = tmpRoot.appendingPathComponent("source")
        originalsDir = tmpRoot.appendingPathComponent("originals")
        previewCacheDir = tmpRoot.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previewCacheDir, withIntermediateDirectories: true)
        catalog = try CatalogDatabase.inMemory()
    }

    override func tearDown() async throws {
        if let dir = tmpRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        tmpRoot = nil
    }

    // MARK: - Successful import ends at .done

    @MainActor
    func testSuccessfulImportReachesDone() async throws {
        try writeTestJPEG(to: sourceDir.appendingPathComponent("a.jpg"))
        try writeTestJPEG(to: sourceDir.appendingPathComponent("b.jpg"))

        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)
        let previewStore = PreviewStore(cacheDirectory: previewCacheDir)
        let coordinator = ImportCoordinator()

        XCTAssertEqual(coordinator.phase, .idle)

        await coordinator.run(
            folderURL: sourceDir,
            importer: importer,
            previewStore: previewStore
        )

        XCTAssertEqual(coordinator.phase, .done)
    }

    // MARK: - Preview count matches import count

    @MainActor
    func testPreviewsGeneratedForAllImportedAssets() async throws {
        try writeTestJPEG(to: sourceDir.appendingPathComponent("one.jpg"))
        try writeTestJPEG(to: sourceDir.appendingPathComponent("two.jpg"))
        try writeTestJPEG(to: sourceDir.appendingPathComponent("three.jpg"))

        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)
        let previewStore = PreviewStore(cacheDirectory: previewCacheDir)
        let coordinator = ImportCoordinator()

        await coordinator.run(
            folderURL: sourceDir,
            importer: importer,
            previewStore: previewStore
        )

        XCTAssertEqual(coordinator.phase, .done)

        // Every imported asset should now have a thumbnail in the cache.
        let assets = try catalog.fetchAssets()
        XCTAssertEqual(assets.count, 3)
        for asset in assets {
            XCTAssertNotNil(
                previewStore.thumbnailURL(for: asset),
                "Missing thumbnail for \(asset.originalFilename)"
            )
        }
    }

    // MARK: - Dedup on second import

    @MainActor
    func testSecondImportSkipsAlreadyImported() async throws {
        try writeTestJPEG(to: sourceDir.appendingPathComponent("x.jpg"))

        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)
        let previewStore = PreviewStore(cacheDirectory: previewCacheDir)
        let coordinator = ImportCoordinator()

        await coordinator.run(
            folderURL: sourceDir,
            importer: importer,
            previewStore: previewStore
        )
        XCTAssertEqual(coordinator.phase, .done)
        XCTAssertEqual(try catalog.fetchAssets().count, 1)

        // Reset and re-run on the same folder.
        coordinator.reset()
        XCTAssertEqual(coordinator.phase, .idle)

        await coordinator.run(
            folderURL: sourceDir,
            importer: importer,
            previewStore: previewStore
        )
        XCTAssertEqual(coordinator.phase, .done)
        // Still only one asset in the catalog — dedup worked.
        XCTAssertEqual(try catalog.fetchAssets().count, 1)
    }

    // MARK: - Empty / nonexistent folder

    @MainActor
    func testNonexistentFolderCompletesWithZeroAssets() async throws {
        // FolderImporter treats a nonexistent folder as empty (the
        // FileManager enumerator returns nil), so the coordinator
        // should complete successfully with no assets imported.
        let badURL = tmpRoot.appendingPathComponent("does-not-exist")
        let importer = FolderImporter(catalog: catalog, originalsDirectory: originalsDir)
        let previewStore = PreviewStore(cacheDirectory: previewCacheDir)
        let coordinator = ImportCoordinator()

        await coordinator.run(
            folderURL: badURL,
            importer: importer,
            previewStore: previewStore
        )

        XCTAssertEqual(coordinator.phase, .done)
        XCTAssertEqual(try catalog.fetchAssets().count, 0)
    }

    // MARK: - Helpers

    /// Writes a tiny valid JPEG to the given URL. Each call produces
    /// distinct pixel content so SHA-256 hashes differ.
    private func writeTestJPEG(to url: URL) throws {
        let width = 8
        let height = 8
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        // Fill with random-ish but deterministic content based on filename.
        let seed = url.lastPathComponent.utf8.reduce(UInt8(0)) { $0 &+ $1 }
        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            pixels[i] = seed &+ UInt8(i & 0xFF)
            pixels[i + 1] = seed &+ UInt8((i >> 1) & 0xFF)
            pixels[i + 2] = seed &+ UInt8((i >> 2) & 0xFF)
            pixels[i + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = pixels.withUnsafeMutableBufferPointer({ ptr in
            CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerPixel * width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }),
              let cgImage = ctx.makeImage() else {
            throw NSError(domain: "ImportCoordinatorTests", code: 1)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ImportCoordinatorTests", code: 2)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImportCoordinatorTests", code: 3)
        }
    }
}
