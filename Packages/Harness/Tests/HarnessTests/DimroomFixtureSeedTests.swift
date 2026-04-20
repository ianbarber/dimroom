import Catalog
import Foundation
import XCTest

/// Drives the `dimroom-fixture` executable as a subprocess so the
/// `--drive-backed` flag's catalog effects can be asserted from Layer A
/// without restructuring the executable target. The binary is built
/// alongside the test target by `swift test`, so finding it via the
/// package bin path is reliable in CI and locally.
final class DimroomFixtureSeedTests: XCTestCase {
    func testDriveBackedAppendsExactlyOneDriveOnlyAsset() async throws {
        let work = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let catalogURL = work.appendingPathComponent("catalog.sqlite")
        let cacheURL = work.appendingPathComponent("previews", isDirectory: true)
        let seedURL = try seedFixturesDirectory()

        try runFixture(arguments: [
            "seed",
            "--catalog", catalogURL.path,
            "--cache", cacheURL.path,
            "--seed-dir", seedURL.path,
            "--drive-backed",
        ])

        let db = try CatalogDatabase(path: catalogURL.path)
        let allAssets = try db.fetchAssets(filter: AssetFilter())
        let driveOnly = allAssets.filter { $0.driveFileId != nil && $0.localPath == nil }
        XCTAssertEqual(driveOnly.count, 1,
            "expected exactly one Drive-only asset; got \(driveOnly.count)")

        let other = allAssets.filter { $0.driveFileId != nil ? false : true }
        for asset in other {
            XCTAssertNil(asset.driveFileId,
                "non-Drive seed assets must have driveFileId == nil")
        }

        let driveAsset = try XCTUnwrap(driveOnly.first)
        XCTAssertEqual(driveAsset.driveFileId, "harness-drive-fixture-file-id")
        XCTAssertEqual(driveAsset.originalFilename, "drive-backed.jpg")

        // Preview JPEG must exist so the grid cell renders during the
        // Layer C flow's screenshot. PreviewStore shards by the first two
        // chars of the content hash: `<cache>/<prefix>/<hash>.*.jpg`.
        let prefix = String(driveAsset.contentHash.prefix(2))
        let shardDir = cacheURL.appendingPathComponent(prefix, isDirectory: true)
        let shardFiles = (try? FileManager.default.contentsOfDirectory(atPath: shardDir.path)) ?? []
        let previewFiles = shardFiles.filter {
            $0.hasPrefix(driveAsset.contentHash) && $0.hasSuffix(".jpg")
        }
        XCTAssertFalse(previewFiles.isEmpty,
            "expected at least one preview JPEG under \(shardDir.path) (found: \(shardFiles))")
    }

    func testWithoutFlagNoDriveOnlyAsset() async throws {
        let work = try makeWorkDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let catalogURL = work.appendingPathComponent("catalog.sqlite")
        let cacheURL = work.appendingPathComponent("previews", isDirectory: true)
        let seedURL = try seedFixturesDirectory()

        try runFixture(arguments: [
            "seed",
            "--catalog", catalogURL.path,
            "--cache", cacheURL.path,
            "--seed-dir", seedURL.path,
        ])

        let db = try CatalogDatabase(path: catalogURL.path)
        let assets = try db.fetchAssets(filter: AssetFilter())
        XCTAssertFalse(assets.isEmpty, "seed should still import the regular fixtures")
        for asset in assets {
            XCTAssertNil(asset.driveFileId,
                "default seed must not produce Drive-backed assets")
        }
    }

    // MARK: - Helpers

    private func makeWorkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-fixture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Resolves the repo's `fixtures/library-seed` directory. The test
    /// bundle lives deep inside the package's `.build` dir (path depth
    /// varies by triple / SwiftPM version), so walk upwards until we
    /// find a directory with both `fixtures/library-seed` and `Packages`
    /// — that's unambiguously the repo / worktree root.
    private func seedFixturesDirectory() throws -> URL {
        var dir = Bundle(for: type(of: self)).bundleURL
        for _ in 0..<12 {
            dir = dir.deletingLastPathComponent()
            let seed = dir.appendingPathComponent("fixtures/library-seed")
            let packages = dir.appendingPathComponent("Packages")
            if FileManager.default.fileExists(atPath: seed.path)
                && FileManager.default.fileExists(atPath: packages.path) {
                return seed
            }
        }
        throw XCTSkip("library-seed fixtures not found walking up from test bundle")
    }

    /// Locates and runs the `dimroom-fixture` executable. The binary
    /// lives next to the test bundle in the same `.build/<triple>/debug`
    /// directory once `swift test` has built the package.
    private func runFixture(arguments: [String]) throws {
        let bundleURL = Bundle(for: type(of: self)).bundleURL
        let binaryURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("dimroom-fixture")
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw XCTSkip("dimroom-fixture binary not found at \(binaryURL.path)")
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTFail("dimroom-fixture exited \(process.terminationStatus): \(err)")
        }
    }
}
