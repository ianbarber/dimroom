import Catalog
import CoreGraphics
import Foundation
import XCTest
@testable import Previews

final class PreviewStoreTests: XCTestCase {

    private var scratchDir: URL!
    private var cacheDir: URL!
    private var fixturesDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helpers

    private func makeAsset(
        contentHash: String = "abc123def456feedbeef",
        width: Int = 4000,
        height: Int = 3000,
        rotation: Int = 0,
        rawFormat: String? = nil
    ) -> Asset {
        Asset(
            contentHash: contentHash,
            originalFilename: "test.jpg",
            sourceType: .digital,
            width: width,
            height: height,
            rawFormat: rawFormat,
            rotation: rotation,
            bytes: 0
        )
    }

    private func makeJPEGFixture(width: Int = 4000, height: Int = 3000) throws -> URL {
        let url = fixturesDir.appendingPathComponent("source-\(UUID().uuidString).jpg")
        try FixtureFactory.makeSyntheticJPEG(width: width, height: height, at: url)
        return url
    }

    // MARK: - Dimensions

    func testGenerateProducesBothFilesAtExpectedDimensions() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset()
        let source = try makeJPEGFixture()

        let set = try await store.generate(for: asset, sourceURL: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: set.thumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: set.preview.path))

        let thumbSize = try XCTUnwrap(FixtureFactory.pixelSize(of: set.thumbnail))
        XCTAssertEqual(max(thumbSize.width, thumbSize.height), 256, accuracy: 1)
        // Aspect ratio preserved: 4000:3000 == 4:3.
        XCTAssertEqual(thumbSize.width / thumbSize.height, 4.0 / 3.0, accuracy: 0.02)

        let previewSize = try XCTUnwrap(FixtureFactory.pixelSize(of: set.preview))
        XCTAssertEqual(max(previewSize.width, previewSize.height), 2048, accuracy: 1)
        XCTAssertEqual(previewSize.width / previewSize.height, 4.0 / 3.0, accuracy: 0.02)
    }

    // MARK: - Idempotency

    func testGenerateIsIdempotentAndDoesNotRedecode() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset()
        let source = try makeJPEGFixture()

        _ = try await store.generate(for: asset, sourceURL: source)
        let firstCount = await store.decodeCount
        XCTAssertEqual(firstCount, 1, "First generate should decode exactly once")

        // Record mtimes, then call again. Neither file should be
        // rewritten and the decode counter must not advance.
        let thumbURL = try XCTUnwrap(store.thumbnailURL(for: asset))
        let previewURL = try XCTUnwrap(store.previewURL(for: asset))

        let fm = FileManager.default
        let firstThumbMtime = try fm.attributesOfItem(atPath: thumbURL.path)[.modificationDate] as? Date
        let firstPreviewMtime = try fm.attributesOfItem(atPath: previewURL.path)[.modificationDate] as? Date

        _ = try await store.generate(for: asset, sourceURL: source)
        let secondCount = await store.decodeCount
        XCTAssertEqual(secondCount, 1, "Second generate must be a no-op and not redecode")

        let secondThumbMtime = try fm.attributesOfItem(atPath: thumbURL.path)[.modificationDate] as? Date
        let secondPreviewMtime = try fm.attributesOfItem(atPath: previewURL.path)[.modificationDate] as? Date
        XCTAssertEqual(firstThumbMtime, secondThumbMtime)
        XCTAssertEqual(firstPreviewMtime, secondPreviewMtime)
    }

    // MARK: - Cache-hit lookup

    func testThumbnailAndPreviewURLReturnNilBeforeGenerationAndURLAfter() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(contentHash: "deadbeef0000000000ff")

        XCTAssertNil(store.thumbnailURL(for: asset))
        XCTAssertNil(store.previewURL(for: asset))

        let source = try makeJPEGFixture(width: 1200, height: 800)
        _ = try await store.generate(for: asset, sourceURL: source)

        XCTAssertNotNil(store.thumbnailURL(for: asset))
        XCTAssertNotNil(store.previewURL(for: asset))
    }

    // MARK: - Invalidation

    func testInvalidateRemovesCachedFilesAndForcesRedecode() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(contentHash: "invalidate00000000aa")
        let source = try makeJPEGFixture()

        // Prime the cache.
        _ = try await store.generate(for: asset, sourceURL: source)
        XCTAssertNotNil(store.thumbnailURL(for: asset))
        XCTAssertNotNil(store.previewURL(for: asset))
        let firstDecode = await store.decodeCount
        XCTAssertEqual(firstDecode, 1)

        // Invalidate — both cached files must vanish and the nonisolated
        // URL accessors must return nil (they're a pure filesystem check).
        await store.invalidate(for: asset)
        XCTAssertNil(store.thumbnailURL(for: asset))
        XCTAssertNil(store.previewURL(for: asset))

        // Next generate should re-decode, proving the cache was
        // genuinely cleared rather than short-circuited.
        _ = try await store.generate(for: asset, sourceURL: source)
        let secondDecode = await store.decodeCount
        XCTAssertEqual(
            secondDecode,
            2,
            "invalidate + generate must force a second decode"
        )
        XCTAssertNotNil(store.thumbnailURL(for: asset))
        XCTAssertNotNil(store.previewURL(for: asset))
    }

    func testInvalidateIsSafeWhenCacheIsEmpty() async {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(contentHash: "neverCached0000000ff")

        // No generate — the cache files don't exist. invalidate must
        // silently do nothing.
        await store.invalidate(for: asset)
        XCTAssertNil(store.thumbnailURL(for: asset))
        XCTAssertNil(store.previewURL(for: asset))
    }

    // MARK: - Rotation

    func testRotationIsAppliedToOutput() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(
            contentHash: "rotated00000000000aa",
            width: 4000,
            height: 3000,
            rotation: 90
        )
        let source = try makeJPEGFixture(width: 4000, height: 3000)

        let set = try await store.generate(for: asset, sourceURL: source)

        // After a 90° rotation the long edge stays 256 but the output
        // should now be portrait-shaped (height > width).
        let thumbSize = try XCTUnwrap(FixtureFactory.pixelSize(of: set.thumbnail))
        XCTAssertEqual(max(thumbSize.width, thumbSize.height), 256, accuracy: 1)
        XCTAssertGreaterThan(thumbSize.height, thumbSize.width,
            "Rotated output should be portrait-shaped, not landscape")

        // Sentinel check: the source has a red top-left quadrant. A 90°
        // CW rotation moves the top-left corner to the top-right. Probe
        // the top-right quadrant of the rotated thumbnail and expect a
        // strongly red average colour.
        let tr = try XCTUnwrap(FixtureFactory.averageColor(
            of: set.thumbnail,
            in: CGRect(
                x: thumbSize.width / 2,
                y: 0,
                width: thumbSize.width / 2,
                height: thumbSize.height / 2
            )
        ))
        XCTAssertGreaterThan(tr.red, 0.6, "Expected red sentinel in top-right after rotation")
        XCTAssertLessThan(tr.green, 0.3)
        XCTAssertLessThan(tr.blue, 0.3)
    }

    // MARK: - CachePaths

    func testCachePathLayoutUsesHashPrefix() {
        let root = URL(fileURLWithPath: "/tmp/previewcache")
        let hash = "ab12cd34ef56"

        let dir = CachePaths.directory(for: hash, in: root)
        XCTAssertEqual(dir.path, "/tmp/previewcache/ab")

        let thumb = CachePaths.fileURL(for: hash, kind: .thumbnail, in: root)
        XCTAssertEqual(thumb.path, "/tmp/previewcache/ab/ab12cd34ef56.thumb.jpg")

        let preview = CachePaths.fileURL(for: hash, kind: .preview, in: root)
        XCTAssertEqual(preview.path, "/tmp/previewcache/ab/ab12cd34ef56.preview.jpg")
    }

    // MARK: - Errors

    func testUnsupportedFormatThrows() async throws {
        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(contentHash: "textfile00000000")

        let bogus = fixturesDir.appendingPathComponent("not-an-image.txt")
        try "hello world\n".data(using: .utf8)!.write(to: bogus)

        do {
            _ = try await store.generate(for: asset, sourceURL: bogus)
            XCTFail("Expected decode/unsupported error")
        } catch PreviewError.unsupportedFormat, PreviewError.decodeFailed {
            // either is acceptable — both indicate we refused to produce
            // previews from a non-image source.
        }
    }

    // MARK: - RAW decode path

    /// If a real DNG fixture is sitting in `fixtures/preview/tiny.dng`
    /// the full RAW path (decode → scale → encode) is exercised against
    /// actual RAW sensor data. The fixture is intentionally not
    /// committed — it would bloat the repo and Core Image's RAW support
    /// varies by camera profile. When the fixture is absent the RAW
    /// branch of `PreviewStore.generate` is still exercised by
    /// `testRAWPathIsTakenWhenAssetHasRawFormat` below.
    func testRAWDecodePathProducesPreview() async throws {
        let fixtureURL = Self.rawFixtureURL()
        guard let fixtureURL, FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("No DNG fixture at fixtures/preview/tiny.dng — skipping end-to-end RAW test")
        }

        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(
            contentHash: "rawhash00000000000bb",
            width: 0,
            height: 0,
            rawFormat: "dng"
        )

        let set = try await store.generate(for: asset, sourceURL: fixtureURL)

        let thumbAttrs = try FileManager.default.attributesOfItem(atPath: set.thumbnail.path)
        let previewAttrs = try FileManager.default.attributesOfItem(atPath: set.preview.path)
        XCTAssertGreaterThan((thumbAttrs[.size] as? Int) ?? 0, 0)
        XCTAssertGreaterThan((previewAttrs[.size] as? Int) ?? 0, 0)

        let previewSize = try XCTUnwrap(FixtureFactory.pixelSize(of: set.preview))
        XCTAssertEqual(max(previewSize.width, previewSize.height), 2048, accuracy: 1)
    }

    /// Exercises the `CIRAWFilter` branch of `PreviewStore.decode`
    /// without needing a valid DNG fixture. `Asset.rawFormat` is set to
    /// `"dng"`, which forces `isRAW` to route the source file through
    /// `CIRAWFilter` instead of `CIImage(contentsOf:)`. The
    /// `rawDecodeCount` counter is the observable signal that the RAW
    /// path was actually taken.
    ///
    /// `CIRAWFilter` on macOS is lenient — it happily decodes ordinary
    /// JPEGs when asked — so `generate` succeeds and we can also assert
    /// that the full preview pipeline works when wired through the RAW
    /// branch, without having to commit a binary RAW fixture.
    func testRAWPathIsTakenWhenAssetHasRawFormat() async throws {
        let jpegURL = try makeJPEGFixture(width: 2000, height: 1500)
        let dngMasqueradeURL = fixturesDir.appendingPathComponent("fake-\(UUID().uuidString).dng")
        try FileManager.default.copyItem(at: jpegURL, to: dngMasqueradeURL)

        let store = PreviewStore(cacheDirectory: cacheDir)
        let asset = makeAsset(
            contentHash: "fakerawhash0000000ff",
            width: 2000,
            height: 1500,
            rawFormat: "dng"
        )

        let set = try await store.generate(for: asset, sourceURL: dngMasqueradeURL)

        let rawCount = await store.rawDecodeCount
        XCTAssertEqual(rawCount, 1, "RAW decode branch should have been taken exactly once")

        XCTAssertTrue(FileManager.default.fileExists(atPath: set.thumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: set.preview.path))
    }

    /// Walk up from `#file` to find the repo root and resolve
    /// `fixtures/preview/tiny.dng`. We don't bundle the DNG as an SPM
    /// resource because it's also useful to other tools in the repo.
    private static func rawFixtureURL() -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        // Packages/Previews/Tests/PreviewsTests/PreviewStoreTests.swift → repo root
        let repoRoot = thisFile
            .deletingLastPathComponent()  // PreviewsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Previews
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        return repoRoot
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("preview", isDirectory: true)
            .appendingPathComponent("tiny.dng", isDirectory: false)
    }
}
