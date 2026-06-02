import Catalog
import Foundation
import Previews
import SwiftUI
import ViewInspector
import XCTest
@testable import UI

/// Structural regression guard that the double-click-to-reset gesture
/// reaches **every** slider in the Develop sidebar.
///
/// The reset gesture lives on `ParameterSlider` (and therefore on
/// `TintedParameterSlider`, which delegates to it). The recurring defect
/// — a new slider control added as a bare `SwiftUI.Slider` that silently
/// skips the reset — bit vignette (#265) and HSL (#318) as separate
/// follow-ups, and most recently the crop **Straighten** control (#426).
/// This test pins the invariant so the next bare slider trips CI instead
/// of shipping.
///
/// ViewInspector 0.10.0 cannot read the contents of a `highPriorityGesture`
/// (its gesture introspection is too weak), so we can't assert
/// "this Slider carries a `TapGesture(count: 2)` reset" directly. Instead
/// we assert the proxy invariant: every `Slider` in the sidebar is wrapped
/// by a `ParameterSlider`, which definitionally carries the reset. Because
/// each `ParameterSlider`/`TintedParameterSlider` body contains exactly one
/// `Slider`, `count(Slider) == count(ParameterSlider)` holds **iff** no bare
/// `Slider` survives.
///
/// Navigation is explicit (sidebar subtree only) rather than via a
/// tree-wide `find`, for the reason documented in
/// `DevelopSidebarStructureTests` / `CropControlsStructureTests`: the
/// Develop `preview` branch's `GeometryReader` / `Image(systemName:)`
/// labels are ViewInspector traversal blockers. `findAll` is scoped to the
/// `sliderColumn` subtree (which has no such blockers) and swallows
/// identification failures, so it counts only the slider stack.
@MainActor
final class SliderResetStructureTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-slider-reset-tests-\(UUID().uuidString)")
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

    /// The main slider stack (`sliderColumn`, `vStack(2)` with crop active)
    /// must contain no bare `Slider` — every `Slider` is wrapped by a
    /// `ParameterSlider`, so the two counts are equal. A future bare slider
    /// added to any sidebar section raises `count(Slider)` above
    /// `count(ParameterSlider)` and trips this assertion.
    func test_slider_column_contains_no_bare_slider() async throws {
        let view = try await makeDevelopView()

        let sliderColumn = try view.inspect()
            .group().hStack(0).scrollView(0).vStack().vStack(2)

        let sliders = sliderColumn.findAll(ViewType.Slider.self).count
        let parameterSliders = sliderColumn.findAll(ParameterSlider.self).count

        XCTAssertGreaterThan(
            parameterSliders,
            0,
            "sanity: the Develop slider column must contain ParameterSliders — a zero count means traversal failed and the invariant below would be vacuous."
        )
        XCTAssertEqual(
            sliders,
            parameterSliders,
            "Every Slider in the Develop slider column must be wrapped by a ParameterSlider (which carries the double-click reset). A bare Slider would skip the reset — the #265 (vignette) / #318 (HSL) regression class."
        )
    }

    /// The crop **Straighten** control lives in `cropSection` (`vStack(1)`),
    /// outside `sliderColumn`, so it needs its own named guard. It was a
    /// bare `Slider` until #426; it must resolve to a `ParameterSlider` so
    /// it inherits the reset like every other slider. cropSection's children
    /// are: Text("Crop") 0, aspect Picker 1, Straighten ParameterSlider 2.
    func test_straighten_row_is_parameter_slider() async throws {
        let view = try await makeDevelopView()

        let straighten = try view.inspect()
            .group().hStack(0).scrollView(0).vStack().vStack(1)
            .view(ParameterSlider.self, 2)

        XCTAssertEqual(
            try straighten.actualView().label,
            "Straighten",
            "The crop Straighten control must route through ParameterSlider so its double-click reset matches every other Develop slider (#426)."
        )
    }

    /// Activates an asset and enters crop mode so the sidebar VStack has a
    /// deterministic three-child structure (mirrors
    /// `DevelopSidebarStructureTests.makeDevelopView`): toolbar HStack (0),
    /// cropSection (1), sliderColumn (2). Crop mode is entered only to pin
    /// the sibling ordering — `sliderColumn` is present regardless.
    private func makeDevelopView() async throws -> DevelopView {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "slider-reset-structure")
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
