import Catalog
@testable import Dimroom
import Previews
import XCTest

/// Layer A retain-leak regression guard for the AppDelegate hot-reload
/// swap (#330, follow-up to #259).
///
/// #259's `CatalogHotReloaderTests` cover the pure file-swap mechanics
/// (atomic replace, validation, sync-state stamping, pending bail). This
/// test exercises the `NSApplication`-bound wiring those mechanics feed
/// into — `wireCatalog` to seed the live catalog, then
/// `applyReloadedCatalog` to swap it — and asserts the *previous*
/// `CatalogDatabase` (and therefore its GRDB `DispatchQueue`) is released
/// once the new one is in place.
///
/// A future change that reintroduces a strong reference pinning the old
/// catalog — a `ContentView.catalog` strong ref, a `HarnessController`
/// holding the catalog directly rather than via a closure-getter, an
/// un-nilled publisher/poller — would leave `weakOld` non-nil and fail
/// here, which is exactly the regression #259 closed by hand and this
/// test now guards automatically.
@MainActor
final class CatalogReloadLeakTests: XCTestCase {

    /// Unique scratch dir created per test. `DIMROOM_ORIGINALS_DIR` is
    /// pointed here so the `OriginalsCache` that `wireCatalog` /
    /// `applyReloadedCatalog` build lands in scratch space instead of the
    /// user's real Application Support.
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogReloadLeakTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("DIMROOM_ORIGINALS_DIR", tempDir.appendingPathComponent("originals").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("DIMROOM_ORIGINALS_DIR")
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    /// The core guard: after a hot-reload swap, nothing pins the
    /// pre-reload catalog.
    func testReloadReleasesPreviousCatalog() async throws {
        let previewStore = PreviewStore(
            cacheDirectory: tempDir.appendingPathComponent("previews")
        )
        let delegate = AppDelegate()

        // Seed the live catalog inside an explicit scope so the strong
        // local is gone before the assertions — only the delegate's
        // wiring should keep `old` alive afterwards.
        weak var weakOld: CatalogDatabase?
        do {
            let old = try CatalogDatabase(
                path: tempDir.appendingPathComponent("old.sqlite").path
            )
            weakOld = old
            delegate.wireCatalog(old, args: [])
        }
        XCTAssertNotNil(weakOld, "delegate should pin the live catalog after wireCatalog")

        // Drive the real swap. `newCatalog` is held locally (and by the
        // delegate), so only the previous catalog is a release candidate.
        let newCatalog = try CatalogDatabase(
            path: tempDir.appendingPathComponent("new.sqlite").path
        )
        await delegate.applyReloadedCatalog(newCatalog, previewStore: previewStore)

        // `configure(...)` cancels the old catalog's in-flight `reload()`
        // task, but that task still strongly captures the old catalog
        // until its background SQLite read returns and the closure
        // deallocs. Wait the cancellation out rather than asserting on a
        // single tick; the wait is bounded so a genuine leak still fails
        // (via the assertion below) instead of hanging.
        await waitUntil { weakOld == nil }
        XCTAssertNil(weakOld, "previous CatalogDatabase leaked after hot-reload swap")
    }

    /// Sanity counterpart: confirm the swap actually happened, so the
    /// nil assertion above can't pass trivially (e.g. if `wireCatalog`
    /// silently failed to install the catalog at all).
    func testReloadRetainsNewCatalog() async throws {
        let previewStore = PreviewStore(
            cacheDirectory: tempDir.appendingPathComponent("previews")
        )
        let delegate = AppDelegate()

        let old = try CatalogDatabase(
            path: tempDir.appendingPathComponent("old.sqlite").path
        )
        delegate.wireCatalog(old, args: [])

        let newCatalog = try CatalogDatabase(
            path: tempDir.appendingPathComponent("new.sqlite").path
        )
        await delegate.applyReloadedCatalog(newCatalog, previewStore: previewStore)

        XCTAssertTrue(
            delegate.catalog === newCatalog,
            "delegate.catalog should point at the reloaded catalog after the swap"
        )
    }

    // MARK: - Helpers

    /// Spin the cooperative pool until `predicate` holds or a short
    /// budget elapses. Bounded so a real leak surfaces as a failed
    /// assertion in the caller rather than a hung test.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
}
