@testable import Dimroom
import Foundation
import Previews
import XCTest

/// Layer A coverage for `AppDelegate.clearPreviewCache(_:thenReloadOn:)` —
/// the shared helper behind both the Settings "Clear preview cache" button
/// (`clearPreviewCacheFromSettings`) and the harness command
/// (`HarnessController.handleClearPreviewCache`).
///
/// The bug this pins (#268): the harness path used to call only
/// `previewStore.removeAll()` and skip the library reload the Settings path
/// performed, so after clearing previews the grid kept rows pointing at
/// deleted thumbnail files. Routing both call sites through this one helper
/// makes the observable effect identical (CLAUDE.md hard rule 4). The test
/// asserts the helper both wipes the on-disk cache *and* fires the reload
/// callback exactly once — a future refactor can't silently drop either half.
///
/// The helper is `static`, so no `AppDelegate` instance (or GUI/`NSApp`
/// lifecycle) is needed; the reload side effect is injected as a closure,
/// which is what makes the shared seam unit-testable.
final class ClearPreviewCacheReloadTests: XCTestCase {

    @MainActor
    func testClearPreviewCacheWipesCacheThenReloadsOnce() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-clearpreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed a stand-in cached preview; `removeAll()` deletes the cache
        // directory's contents, so this file must be gone afterwards.
        let sentinel = tmp.appendingPathComponent("sentinel.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: sentinel)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            "sentinel preview file should exist before clearing"
        )

        let store = PreviewStore(cacheDirectory: tmp)
        var reloadCount = 0

        await AppDelegate.clearPreviewCache(store) {
            reloadCount += 1
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinel.path),
            "clearPreviewCache should wipe the on-disk preview cache"
        )
        XCTAssertEqual(
            reloadCount, 1,
            "clearPreviewCache should reload the library exactly once after wiping"
        )
    }
}
