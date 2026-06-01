import Catalog
import Foundation
import Previews
import SwiftUI
import ViewInspector
import XCTest
@testable import UI

/// Explicit regression guard that the Develop sidebar composes the HSL
/// panel **exactly once** (#317 / its already-fixed duplicate #299). The
/// original defect was a stray second `hslSection` reference in
/// `DevelopView` that rendered `HSLPanelView` twice; PR #337 deleted the
/// duplicate but added no dedicated assertion. The standard 1024×768
/// Develop snapshots cut off below the HSL section, which is exactly why
/// the duplicate slipped through, so a structural count is the right
/// guard rather than another short snapshot.
///
/// Navigation is explicit (sidebar subtree only) rather than via `find`,
/// for the same reason documented in `DarkThemeControlStructureTests` and
/// `CropControlsStructureTests`: the Develop `preview` branch's
/// `GeometryReader` / `Image(systemName:)` labels are ViewInspector
/// traversal blockers, so a tree-wide search aborts. Counting matches
/// (rather than asserting a fixed total child count) keeps the test robust
/// to legitimately adding or removing other slider sections later.
@MainActor
final class DevelopSidebarStructureTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-develop-sidebar-tests-\(UUID().uuidString)")
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

    /// With crop mode active the sidebar VStack children are, in order:
    /// toolbar HStack (0), cropSection (1), sliderColumn (2) — the same
    /// deterministic shape `DarkThemeControlStructureTests` relies on. The
    /// HSL panel lives inside `sliderColumn`; iterating its direct children
    /// and counting `HSLPanelView` matches detects a re-introduced
    /// duplicate regardless of where in the column it lands.
    func test_sidebar_composes_hsl_panel_exactly_once() async throws {
        let view = try await makeDevelopView()

        let sliderColumn = try view.inspect()
            .group().hStack(0).scrollView(0).vStack().vStack(2)

        var hslCount = 0
        for index in 0..<sliderColumn.count
        where (try? sliderColumn.view(HSLPanelView.self, index)) != nil {
            hslCount += 1
        }

        XCTAssertEqual(
            hslCount,
            1,
            "HSL panel must be composed into the Develop sidebar exactly once — duplicate hslSection regression (#317 / #299)."
        )
    }

    /// Activates an asset and enters crop mode so the sidebar VStack has a
    /// deterministic three-child structure (mirrors
    /// `DarkThemeControlStructureTests.makeDevelopView`). The HSL panel
    /// lives in `sliderColumn`, which is present regardless of crop state;
    /// crop mode is entered only to pin the sibling ordering for explicit
    /// index navigation.
    private func makeDevelopView() async throws -> DevelopView {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "develop-sidebar-hsl-once")
        try catalog.insertAsset(asset)
        try TestFixtures.placePreview(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 100, g: 100, b: 100)
        )
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = DevelopViewModel(catalog: catalog, previewStore: store)
        await vm.activate(assetId: asset.id)
        vm.enterCropMode()
        XCTAssertTrue(vm.cropViewModel.isActive)
        XCTAssertNotNil(vm.currentAssetId)
        return DevelopView(viewModel: vm)
    }
}
