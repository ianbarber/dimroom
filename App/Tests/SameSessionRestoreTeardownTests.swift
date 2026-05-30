import Catalog
@testable import Dimroom
import SyncEngine
import XCTest

/// Integration coverage for the destructive half of the same-session
/// restore (#293 follow-up, #339). The pure-predicate tests in
/// `SameSessionRestoreGateTests` pin `shouldRunSameSessionRestore`'s
/// `count == 0` decision but say nothing about whether the orchestration
/// actually reads the live count from a real catalog and bails *before*
/// teardown. `performSameSessionRestore` is the orchestration lifted off
/// `AppDelegate` so we can drive it with a seeded `CatalogDatabase` and
/// spy on the injected effects — proving the guard genuinely gates the
/// teardown, not just the predicate.
///
/// Marked `@MainActor` so the injected `@MainActor` effect closures form
/// and run in the same isolation domain the production adapter uses; the
/// helper itself is `nonisolated static`, so no `AppDelegate` (and no
/// `NSApplication`) is constructed.
@MainActor
final class SameSessionRestoreTeardownTests: XCTestCase {

    // MARK: - Fixture plumbing

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SameSessionRestoreTeardownTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Seeds a real on-disk catalog with `count` live assets so the
    /// helper reads the same `countAssets()` the production path does,
    /// not a stubbed integer.
    private func makeCatalog(withAssets count: Int, at path: String) throws -> CatalogDatabase {
        let db = try CatalogDatabase(path: path)
        for index in 0..<count {
            try db.insertAsset(
                Asset(
                    contentHash: "seed-\(index)",
                    originalFilename: "IMG_\(index).CR3",
                    sourceType: .digital,
                    width: 6000,
                    height: 4000,
                    bytes: 1_000
                )
            )
        }
        return db
    }

    // MARK: - #293: placeholder holds imports → bail before teardown

    func testPlaceholderWithImportsSkipsTeardownAndKeepsCatalog() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("catalog.sqlite").path
        // Held for the duration so the file stays open during the call,
        // matching the live launch-path catalog the guard protects.
        let catalog = try makeCatalog(withAssets: 3, at: path)

        var teardownCalled = false
        var removeItemCalled = false
        var restoreCalled = false
        var reopenCalled = false

        await AppDelegate.performSameSessionRestore(
            placeholderCatalog: catalog,
            catalogPath: path,
            teardown: { teardownCalled = true },
            // Records the call *and* performs the real deletion, so that
            // if the guard is removed the assertions below catch both the
            // fired effect and the vanished file.
            removeItem: { removed in
                removeItemCalled = true
                try FileManager.default.removeItem(atPath: removed)
            },
            restore: { restoreCalled = true; return .noRemoteCatalog },
            reopenAndWire: { reopenCalled = true },
            onFailure: { _ in }
        )

        XCTAssertFalse(teardownCalled, "guard must bail before tearing down the live catalog wiring")
        XCTAssertFalse(removeItemCalled, "the placeholder catalog file must not be deleted")
        XCTAssertFalse(restoreCalled, "the destructive restore must not run")
        XCTAssertFalse(reopenCalled, "no re-wire happens on the bail path")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "the user's imported catalog must survive on disk"
        )
        XCTAssertEqual(try catalog.countAssets(), 3, "the imported rows are untouched")
    }

    // MARK: - #283 happy path: empty placeholder → full teardown + restore

    func testEmptyPlaceholderRunsTeardownAndRestore() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("catalog.sqlite").path
        let catalog = try makeCatalog(withAssets: 0, at: path)

        var teardownCalled = false
        var removeItemCalled = false
        var restoreCalled = false
        var reopenCalled = false

        await AppDelegate.performSameSessionRestore(
            placeholderCatalog: catalog,
            catalogPath: path,
            teardown: { teardownCalled = true },
            removeItem: { _ in removeItemCalled = true },
            restore: { restoreCalled = true; return .noRemoteCatalog },
            reopenAndWire: { reopenCalled = true },
            onFailure: { _ in }
        )

        XCTAssertTrue(teardownCalled, "an empty placeholder is safe to tear down")
        XCTAssertTrue(removeItemCalled, "the pristine placeholder file is removed before restore")
        XCTAssertTrue(restoreCalled, "the remote catalog restore runs")
        XCTAssertTrue(reopenCalled, "the view models are re-wired to the restored catalog")
    }

    // MARK: - nil / unreadable catalog → count collapses to 0, restore proceeds

    func testNilPlaceholderProceedsWithRestore() async throws {
        var teardownCalled = false
        var restoreCalled = false

        await AppDelegate.performSameSessionRestore(
            placeholderCatalog: nil,
            catalogPath: "/tmp/dimroom-same-session-restore-nil.sqlite",
            teardown: { teardownCalled = true },
            removeItem: { _ in },
            restore: { restoreCalled = true; return .noRemoteCatalog },
            reopenAndWire: {},
            onFailure: { _ in }
        )

        XCTAssertTrue(teardownCalled, "a nil placeholder collapses to count 0, so restore proceeds")
        XCTAssertTrue(restoreCalled, "a transient read failure must not permanently block restore")
    }
}
