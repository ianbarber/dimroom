import Catalog
@testable import Dimroom
import Foundation
import Harness
import Previews
import UI
import XCTest

/// Layer A coverage for the dynamic-flip gap PR #206 deferred.
///
/// PR #206's static `inspect-menu Edit` assertion in
/// `bin/harness-multi-select-delete-flow.sh` catches the
/// "DeleteMenuItem dropped from `.commands`" and
/// "`.keyboardShortcut(.delete)` dropped" regressions at scene-creation
/// time — but it cannot observe the menu item flipping from
/// disabled → enabled once assets are selected, because SwiftUI does
/// not re-render its `.commands` tree onto `NSMenuItem.isEnabled`
/// without an active UI cycle (see that flow script's docstring).
///
/// Issue #208 asks for option (b) from #183: a Layer A test against
/// the predicate that feeds `.disabled(...)`. `DeleteMenuItem.isDisabled`
/// is the single source of truth; if a regression inverts it
/// (e.g. swaps `isEmpty` for `!isEmpty`, or drops the scope clause),
/// these tests fail. We assert the property directly rather than
/// trying to walk SwiftUI's `Button.disabled` modifier, which would
/// require a third-party view-introspection dependency for no
/// additional regression-detection power.
@MainActor
final class DeleteMenuItemEnablementTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-delete-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempCacheDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

    // MARK: - The flip (selection → enabled in Library)

    /// The case the issue calls out: empty selection in `.library`
    /// must disable the menu item, then making a selection must flip
    /// it to enabled — without any other state changing.
    func testEnablementFlipsWithSelectionInLibrary() async throws {
        let vm = try await makeViewModel()
        let router = AppRouter()
        router.route = .library

        let item = DeleteMenuItem(libraryViewModel: vm, router: router)
        XCTAssertTrue(item.isDisabled, "no selection → disabled")

        let firstId = try XCTUnwrap(vm.rows.first?.id)
        vm.select(firstId)

        XCTAssertFalse(item.isDisabled, "selection in Library → enabled")
    }

    // MARK: - Scope clause (selection alone is not enough)

    func testDisabledInLoupeEvenWithSelection() async throws {
        let vm = try await makeViewModel()
        let router = AppRouter()
        router.route = .loupe
        let firstId = try XCTUnwrap(vm.rows.first?.id)
        vm.select(firstId)

        let item = DeleteMenuItem(libraryViewModel: vm, router: router)
        XCTAssertTrue(
            item.isDisabled,
            "selection alone is not enough — Loupe is out of scope for Delete"
        )
    }

    func testDisabledInDevelopEvenWithSelection() async throws {
        let vm = try await makeViewModel()
        let router = AppRouter()
        router.route = .develop
        let firstId = try XCTUnwrap(vm.rows.first?.id)
        vm.select(firstId)

        let item = DeleteMenuItem(libraryViewModel: vm, router: router)
        XCTAssertTrue(
            item.isDisabled,
            "selection alone is not enough — Develop is out of scope for Delete"
        )
    }

    /// `.recentlyDeleted` scope shows already-trashed rows; Delete is a
    /// no-op there and must stay disabled even with a selection in Library.
    /// Catches a regression that drops the `scope == .recentlyDeleted`
    /// clause from `isDisabled`.
    func testDisabledInRecentlyDeletedScopeEvenWithSelection() async throws {
        let vm = try await makeViewModel()
        let router = AppRouter()
        router.route = .library

        // Soft-delete one of the seeded assets, then switch to the
        // Recently Deleted scope so the row remains visible — keeping the
        // selection stable across `reloadAndWait`'s `intersection(visible)`
        // step. Without this, switching scope to `.recentlyDeleted` would
        // empty `rows` and clear the selection, masking the scope clause.
        let firstId = try XCTUnwrap(vm.rows.first?.id)
        await vm.deleteAssets(ids: [firstId])
        await vm.setScope(.recentlyDeleted)
        let trashedId = try XCTUnwrap(vm.rows.first?.id)
        vm.select(trashedId)

        let item = DeleteMenuItem(libraryViewModel: vm, router: router)
        XCTAssertTrue(
            item.isDisabled,
            "selection in the trash scope must not enable Delete"
        )
    }

    // MARK: - Sanity (both clauses disabling)

    func testDisabledWithEmptySelectionInLibrary() async throws {
        let vm = try await makeViewModel()
        let router = AppRouter()
        router.route = .library

        let item = DeleteMenuItem(libraryViewModel: vm, router: router)
        XCTAssertTrue(item.isDisabled)
    }

    func testDisabledWithEmptySelectionInLoupe() async throws {
        let vm = try await makeViewModel()
        let router = AppRouter()
        router.route = .loupe

        let item = DeleteMenuItem(libraryViewModel: vm, router: router)
        XCTAssertTrue(item.isDisabled)
    }

    // MARK: - Helpers

    /// Build a `LibraryViewModel` backed by an in-memory catalog with
    /// two seeded assets. Two rows is enough to make `vm.select(id)`
    /// stick across the reload that `reloadAndWait` triggers — the
    /// reload's `intersection(visible)` step would clear a selection
    /// whose id is not in `rows`.
    private func makeViewModel() async throws -> LibraryViewModel {
        let catalog = try CatalogDatabase.inMemory()
        for i in 0..<2 {
            try catalog.insertAsset(
                Asset(
                    contentHash: "delete-menu-\(i)",
                    originalFilename: "asset-\(i).jpg",
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(i)),
                    sourceType: .digital,
                    width: 100,
                    height: 100,
                    bytes: 0
                )
            )
        }
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        await vm.reloadAndWait()
        XCTAssertEqual(vm.rows.count, 2, "fixture should seed two rows")
        return vm
    }
}
