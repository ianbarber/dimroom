import Catalog
import Foundation
import Previews
import SwiftUI
import ViewInspector
import XCTest
@testable import UI

/// Load-bearing regression guard for the two controls #326 newly brought
/// under the dark-theme convention: the HSL **Axis** segmented `Picker`
/// (`HSLPanelView`) and the Curves **Channel** segmented `Picker`
/// (`DevelopView`). Both are `NSSegmentedControl`-backed, so they render
/// segment labels through the system control foreground path and show
/// near-black text against the dark sidebar unless `.colorScheme(.dark)`
/// is forced — the same bug class as the Library rating picker (#241).
///
/// The fix is the shared `.darkThemeControl()` modifier, which applies
/// `.colorScheme(.dark)`. This test asserts that environment value stays
/// attached so a future stylist can't silently drop the modifier. An
/// `ImageRenderer`/`cacheDisplay` Layer B snapshot can't catch the
/// regression because the offline render path ignores `NSSegmentedControl`'s
/// live AppKit drawing — see `FilterBarStructureTests` for the same
/// rendering-path-divergence rationale.
@MainActor
final class DarkThemeControlStructureTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-darktheme-tests-\(UUID().uuidString)")
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

    /// The modifier itself: applying `.darkThemeControl()` must yield the
    /// dark colour scheme in the environment. Guards the modifier's body
    /// independently of any one call site.
    func test_darkThemeControl_applies_dark_color_scheme() throws {
        let scheme = try Text("contrast")
            .darkThemeControl()
            .inspect()
            .text()
            .environment(\.colorScheme)

        XCTAssertEqual(
            scheme,
            .dark,
            ".darkThemeControl() must apply .colorScheme(.dark) — that is the proven lever for AppKit-backed controls (#241)."
        )
    }

    /// HSL Axis picker — `HSLPanelView` body is
    /// `VStack { Text("HSL"); Picker; VStack(sliders) }`, so the axis
    /// picker is `vStack().picker(1)`.
    func test_hsl_axis_picker_has_dark_color_scheme() throws {
        let view = HSLPanelView(
            value: { _, _ in 0 },
            setValue: { _, _, _ in },
            reset: { _, _ in }
        )

        let picker = try view.inspect().vStack().picker(1)
        let scheme = try picker.environment(\.colorScheme)

        XCTAssertEqual(
            scheme,
            .dark,
            "HSL Axis Picker must carry .darkThemeControl() — NSSegmentedControl renders its segment labels near-black against the dark sidebar otherwise (#326)."
        )
    }

    /// Curves Channel picker, navigated explicitly (not via `find`) because
    /// the Develop `preview` branch's `GeometryReader` / `Image(systemName:)`
    /// labels are ViewInspector traversal blockers — same reason documented
    /// in `CropControlsStructureTests`. With crop mode active the sidebar
    /// VStack children are, in order: toolbar HStack (0), cropSection (1),
    /// sliderColumn (2). Inside sliderColumn the Curves group is the 4th
    /// child (3); its VStack is `Text("Curves"); Picker; CurveEditorView`,
    /// so the channel picker is `picker(1)`.
    func test_curve_channel_picker_has_dark_color_scheme() async throws {
        let view = try await makeDevelopView()

        let sidebar = try view.inspect().group().hStack(0).scrollView(0).vStack()
        let picker = try sidebar.vStack(2).vStack(3).picker(1)
        let scheme = try picker.environment(\.colorScheme)

        XCTAssertEqual(
            scheme,
            .dark,
            "Curves Channel Picker must carry .darkThemeControl() — NSSegmentedControl renders its segment labels near-black against the dark sidebar otherwise (#326)."
        )
    }

    /// Activates an asset and enters crop mode so the sidebar VStack has a
    /// deterministic three-child structure (mirrors
    /// `CropControlsStructureTests.makeCropActiveView`). The channel picker
    /// lives in `sliderColumn`, which is present regardless of crop state;
    /// crop mode is entered only to pin the sibling ordering for explicit
    /// index navigation.
    private func makeDevelopView() async throws -> DevelopView {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "darktheme-channel-picker")
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
