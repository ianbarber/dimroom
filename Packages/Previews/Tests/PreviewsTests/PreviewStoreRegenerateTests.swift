import Catalog
import Combine
import CoreGraphics
import CryptoKit
import EditEngine
import Foundation
import XCTest
@testable import Previews

final class PreviewStoreRegenerateTests: XCTestCase {

    private var scratchDir: URL!
    private var cacheDir: URL!
    private var fixturesDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewStoreRegenerateTests-\(UUID().uuidString)", isDirectory: true)
        cacheDir = scratchDir.appendingPathComponent("cache", isDirectory: true)
        fixturesDir = scratchDir.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDir, FileManager.default.fileExists(atPath: scratchDir.path) {
            try FileManager.default.removeItem(at: scratchDir)
        }
    }

    private func makeAsset(hash: String = "regen0000000000000ab") -> Asset {
        Asset(
            contentHash: hash,
            originalFilename: "test.jpg",
            sourceType: .digital,
            width: 1200,
            height: 800,
            rawFormat: nil,
            rotation: 0,
            bytes: 0
        )
    }

    private func makeSource(width: Int = 1200, height: Int = 800) throws -> URL {
        let url = fixturesDir.appendingPathComponent("src-\(UUID().uuidString).jpg")
        try FixtureFactory.makeSyntheticJPEG(width: width, height: height, at: url)
        return url
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tests

    func testRegenerateWithEditOverwritesCachedFiles() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenoverwrite000000a")
        let source = try makeSource()
        let set = try await store.generate(for: asset, sourceURL: source)

        let thumbBefore = try sha256(of: set.thumbnail)
        let previewBefore = try sha256(of: set.preview)

        var state = EditState()
        state.exposure = 2.0
        await store.regenerateWithEdit(for: asset, editState: state)

        XCTAssertTrue(FileManager.default.fileExists(atPath: set.thumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: set.preview.path))

        let thumbAfter = try sha256(of: set.thumbnail)
        let previewAfter = try sha256(of: set.preview)

        XCTAssertNotEqual(thumbBefore, thumbAfter, "Thumbnail bytes must change after regenerate with non-identity edit")
        XCTAssertNotEqual(previewBefore, previewAfter, "Preview bytes must change after regenerate with non-identity edit")
    }

    func testRegenerateWithIdentityStateKeepsVisuallyEquivalentOutput() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenidentity000000ab")
        let source = try makeSource()
        let set = try await store.generate(for: asset, sourceURL: source)

        guard let beforeSize = FixtureFactory.pixelSize(of: set.thumbnail) else {
            return XCTFail("missing thumbnail size")
        }
        let beforeAvg = FixtureFactory.averageColor(
            of: set.thumbnail,
            in: CGRect(origin: .zero, size: beforeSize)
        )

        await store.regenerateWithEdit(for: asset, editState: EditState())

        XCTAssertTrue(FileManager.default.fileExists(atPath: set.thumbnail.path))
        guard let afterSize = FixtureFactory.pixelSize(of: set.thumbnail) else {
            return XCTFail("missing thumbnail size after regenerate")
        }
        XCTAssertEqual(max(afterSize.width, afterSize.height), 256, accuracy: 1)

        // Mean colour should be close to the original; JPEG re-encode
        // introduces small deltas but the overall average must track.
        if let beforeAvg,
           let afterAvg = FixtureFactory.averageColor(
               of: set.thumbnail,
               in: CGRect(origin: .zero, size: afterSize)
           ) {
            XCTAssertEqual(beforeAvg.red, afterAvg.red, accuracy: 0.1)
            XCTAssertEqual(beforeAvg.green, afterAvg.green, accuracy: 0.1)
            XCTAssertEqual(beforeAvg.blue, afterAvg.blue, accuracy: 0.1)
        }
    }

    func testRegenerateWithMissingPreviewIsNoOp() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regennomissing00000ac")

        XCTAssertNil(store.thumbnailURL(for: asset))
        XCTAssertNil(store.previewURL(for: asset))

        var state = EditState()
        state.exposure = 1.0
        await store.regenerateWithEdit(for: asset, editState: state)

        // No preview cache existed, so regenerate must leave the cache
        // empty rather than creating half-written JPEGs.
        XCTAssertNil(store.thumbnailURL(for: asset))
        XCTAssertNil(store.previewURL(for: asset))
    }

    func testRegenerateEmitsPreviewRegeneratedSignal() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regensignal0000000ad0")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        let expectation = XCTestExpectation(description: "previewRegenerated emits asset id")
        var cancellables = Set<AnyCancellable>()
        var received: [UUID] = []
        store.previewRegenerated
            .sink { id in
                received.append(id)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        var state = EditState()
        state.exposure = 1.5
        await store.regenerateWithEdit(for: asset, editState: state)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(received, [asset.id])
    }

    func testRegenerateWithMissingPreviewDoesNotEmitSignal() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regennosignal00000ae0")

        var cancellables = Set<AnyCancellable>()
        var received: [UUID] = []
        store.previewRegenerated
            .sink { received.append($0) }
            .store(in: &cancellables)

        var state = EditState()
        state.exposure = 1.0
        await store.regenerateWithEdit(for: asset, editState: state)

        XCTAssertTrue(received.isEmpty, "No signal should fire when there is no preview to regenerate")
    }
}
