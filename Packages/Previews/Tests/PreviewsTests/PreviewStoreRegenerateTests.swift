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

    private func masterURL(for asset: Asset, kind: PreviewKind) -> URL {
        CachePaths.fileURL(for: asset, kind: kind, tier: .master, in: cacheDir)
    }

    private func displayURL(for asset: Asset, kind: PreviewKind) -> URL {
        CachePaths.fileURL(for: asset, kind: kind, tier: .display, in: cacheDir)
    }

    // MARK: - Tests

    func testRegenerateWithEditWritesDisplayTierAndLeavesMasterAlone() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenoverwrite000000a")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        let masterThumb = masterURL(for: asset, kind: .thumbnail)
        let masterPreview = masterURL(for: asset, kind: .preview)
        let displayThumb = displayURL(for: asset, kind: .thumbnail)
        let displayPreview = displayURL(for: asset, kind: .preview)

        let masterThumbBefore = try sha256(of: masterThumb)
        let masterPreviewBefore = try sha256(of: masterPreview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayThumb.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayPreview.path))

        var state = EditState()
        state.exposure = 2.0
        await store.regenerateWithEdit(for: asset, editState: state)

        // Display files now exist with edited bytes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: displayThumb.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displayPreview.path))
        XCTAssertNotEqual(
            try sha256(of: displayThumb),
            masterThumbBefore,
            "Display thumbnail must differ from master after a non-identity edit"
        )
        XCTAssertNotEqual(
            try sha256(of: displayPreview),
            masterPreviewBefore,
            "Display preview must differ from master after a non-identity edit"
        )

        // Master files are byte-identical to before — they're the source
        // of truth for future regens and must never be rewritten.
        XCTAssertEqual(try sha256(of: masterThumb), masterThumbBefore)
        XCTAssertEqual(try sha256(of: masterPreview), masterPreviewBefore)
    }

    func testRegenerateWithIdentityStateLeavesMasterPristine() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenidentity000000ab")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        let masterThumb = masterURL(for: asset, kind: .thumbnail)
        let masterThumbBefore = try sha256(of: masterThumb)

        await store.regenerateWithEdit(for: asset, editState: EditState())

        XCTAssertTrue(FileManager.default.fileExists(atPath: masterThumb.path))
        XCTAssertEqual(try sha256(of: masterThumb), masterThumbBefore)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: displayURL(for: asset, kind: .thumbnail).path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: displayURL(for: asset, kind: .preview).path)
        )
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

    // MARK: - Issue #186 — generational loss

    /// Repeated regens with the same non-identity edit must produce
    /// byte-identical display JPEGs, proving each call reads from the
    /// (unchanged) master rather than from the previously rendered
    /// display tier.
    func testRegenerateIsIdempotentAcrossRepeatedCalls() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenidempotent00aaff")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        var state = EditState()
        state.exposure = 1.5
        state.contrast = 20

        await store.regenerateWithEdit(for: asset, editState: state)
        let firstThumbSHA = try sha256(of: displayURL(for: asset, kind: .thumbnail))
        let firstPreviewSHA = try sha256(of: displayURL(for: asset, kind: .preview))

        for _ in 0..<5 {
            await store.regenerateWithEdit(for: asset, editState: state)
            XCTAssertEqual(
                try sha256(of: displayURL(for: asset, kind: .thumbnail)),
                firstThumbSHA,
                "Repeated regen must produce byte-identical display thumbnail"
            )
            XCTAssertEqual(
                try sha256(of: displayURL(for: asset, kind: .preview)),
                firstPreviewSHA,
                "Repeated regen must produce byte-identical display preview"
            )
        }
    }

    /// Master files are the canonical source of truth — a non-identity
    /// regen must not mutate them. Catches the bug where regen reads its
    /// own previous output as the source (issue #186).
    func testRegenerateDoesNotModifyMasterFiles() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenmasterintact00aa")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        let masterThumb = masterURL(for: asset, kind: .thumbnail)
        let masterPreview = masterURL(for: asset, kind: .preview)
        let masterThumbSHA = try sha256(of: masterThumb)
        let masterPreviewSHA = try sha256(of: masterPreview)

        var state = EditState()
        state.exposure = 2.5

        for _ in 0..<3 {
            await store.regenerateWithEdit(for: asset, editState: state)
            XCTAssertEqual(try sha256(of: masterThumb), masterThumbSHA)
            XCTAssertEqual(try sha256(of: masterPreview), masterPreviewSHA)
        }
    }

    /// A second crop must operate against the full-resolution master, not
    /// against the smaller display JPEG produced by the first crop —
    /// otherwise re-cropping a previously-cropped image silently degrades
    /// resolution on every iteration (the crop-shrinks-the-source case
    /// from issue #186).
    func testRegenerateAfterCropReadsMasterNotDisplay() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regencropfrommastr00")
        // Source must be big enough that the 2048px master is strictly
        // larger than the first-crop display, otherwise the bug can't
        // produce observable shrinkage.
        let source = try makeSource(width: 4000, height: 3000)
        _ = try await store.generate(for: asset, sourceURL: source)

        let masterPreview = masterURL(for: asset, kind: .preview)
        let masterSize = try XCTUnwrap(FixtureFactory.pixelSize(of: masterPreview))
        XCTAssertEqual(max(masterSize.width, masterSize.height), 2048, accuracy: 1)

        // First crop: centered 50% × 50%.
        var firstCrop = EditState()
        firstCrop.cropRect = CGRect(
            x: masterSize.width * 0.25,
            y: masterSize.height * 0.25,
            width: masterSize.width * 0.5,
            height: masterSize.height * 0.5
        )
        await store.regenerateWithEdit(for: asset, editState: firstCrop)

        let displayPreview = displayURL(for: asset, kind: .preview)
        let firstSize = try XCTUnwrap(FixtureFactory.pixelSize(of: displayPreview))

        // Second crop: a *larger* centered region (75% × 75%). Under the
        // pre-#186 bug the second regen would read the smaller first-crop
        // display as source and end up smaller still; with the fix it
        // reads the 2048px master and ends up larger than the first crop.
        var secondCrop = EditState()
        secondCrop.cropRect = CGRect(
            x: masterSize.width * 0.125,
            y: masterSize.height * 0.125,
            width: masterSize.width * 0.75,
            height: masterSize.height * 0.75
        )
        await store.regenerateWithEdit(for: asset, editState: secondCrop)

        let secondSize = try XCTUnwrap(FixtureFactory.pixelSize(of: displayPreview))
        XCTAssertGreaterThan(
            secondSize.width,
            firstSize.width,
            "Second (larger) crop must operate on the 2048px master — got \(secondSize) after first \(firstSize)"
        )
    }

    /// After a non-identity regen has written display files, a fresh
    /// identity regen must remove them so `thumbnailURL` / `previewURL`
    /// resolve back to master.
    func testRegenerateWithIdentityEditDeletesDisplayFiles() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "regenidresetdisp00aa")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        var state = EditState()
        state.exposure = 1.0
        await store.regenerateWithEdit(for: asset, editState: state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displayURL(for: asset, kind: .thumbnail).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displayURL(for: asset, kind: .preview).path))

        await store.regenerateWithEdit(for: asset, editState: EditState())

        XCTAssertFalse(FileManager.default.fileExists(atPath: displayURL(for: asset, kind: .thumbnail).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayURL(for: asset, kind: .preview).path))

        XCTAssertEqual(store.thumbnailURL(for: asset), masterURL(for: asset, kind: .thumbnail))
        XCTAssertEqual(store.previewURL(for: asset), masterURL(for: asset, kind: .preview))
    }

    /// Lookup contract: with no display files, `previewURL` returns the
    /// master; after a non-identity regen it returns the display tier.
    /// The `master*URL` accessors always return master regardless.
    func testPreviewURLFallsBackToMasterWhenNoDisplay() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(hash: "previewfallback0000a")
        let source = try makeSource()
        _ = try await store.generate(for: asset, sourceURL: source)

        XCTAssertEqual(store.previewURL(for: asset), masterURL(for: asset, kind: .preview))
        XCTAssertEqual(store.thumbnailURL(for: asset), masterURL(for: asset, kind: .thumbnail))

        var state = EditState()
        state.exposure = 0.75
        await store.regenerateWithEdit(for: asset, editState: state)

        XCTAssertEqual(store.previewURL(for: asset), displayURL(for: asset, kind: .preview))
        XCTAssertEqual(store.thumbnailURL(for: asset), displayURL(for: asset, kind: .thumbnail))
        XCTAssertEqual(store.masterPreviewURL(for: asset), masterURL(for: asset, kind: .preview))
        XCTAssertEqual(store.masterThumbnailURL(for: asset), masterURL(for: asset, kind: .thumbnail))
    }
}
