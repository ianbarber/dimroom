import Catalog
import Foundation
import Previews
import SwiftUI
import ViewInspector
import XCTest
@testable import UI

/// Structural regression guard for the crop tool's sidebar controls in
/// `DevelopView` — the crop toggle `Button` and the aspect-ratio `Picker`.
/// Both are residual instances of the black-on-dark-gray class fixed for
/// the scope picker (#74) and the Library filter bar (#241): a `.bordered`
/// `Button` renders its label in the (dark) tint colour, and a `.menu`
/// `Picker`'s selected-value label inherits a near-black foreground against
/// the dark sidebar. The fix pins `.foregroundStyle(.white)` on the button
/// label's children and on the picker (plus `.tint(.white)` on the picker
/// for chevron / selection-indicator contrast).
///
/// A Layer B `ImageRenderer` snapshot can't catch a regression here, for the
/// same reason documented in `ScopePickerStructureTests` and
/// `FilterBarStructureTests`: `ImageRenderer` propagates a container-level
/// foreground into a Button label's subtree and ignores the AppKit control
/// rendering path a live `Picker`/`Button` actually uses — so the pre-fix
/// and post-fix views produce identical PNGs. This test asserts the
/// modifiers stay attached so a future stylist can't silently drop them.
///
/// Navigation is explicit (sidebar subtree only) rather than via `find`:
/// the `preview` branch's `GeometryReader` and `Image(systemName:)` labels
/// are ViewInspector traversal blockers, so a tree-wide search aborts.
///
/// Note: `.tint(.white)` is intentionally not asserted — ViewInspector
/// 0.10.0 exposes no inspector for the `.tint` modifier. It remains in the
/// source for the picker's selection-indicator contrast (AC 3 of #319).
@MainActor
final class CropControlsStructureTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-crop-controls-tests-\(UUID().uuidString)")
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

    /// Activates an asset and enters crop mode so the body renders the
    /// slider sidebar with both the crop toggle and the (conditionally
    /// shown) crop section's aspect-ratio picker.
    private func makeCropActiveView() async throws -> DevelopView {
        let catalog = try CatalogDatabase.inMemory()
        let asset = TestFixtures.makeAsset(hash: "crop-controls-structure")
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

    /// The slider-sidebar VStack: body Group → HStack[sidebar, preview] →
    /// ScrollView → VStack. With crop mode active its children are, in
    /// order: cropToggle (Button, 0), cropSection (VStack, 1), sliderColumn
    /// (VStack, 2).
    private func sidebarVStack(
        _ view: DevelopView
    ) throws -> InspectableView<ViewType.VStack> {
        try view.inspect().group().hStack(0).scrollView(0).vStack()
    }

    func test_crop_toggle_label_children_are_white() async throws {
        let view = try await makeCropActiveView()

        let hstack = try sidebarVStack(view).button(0).labelView().hStack()

        // The icon's `.foregroundStyle(.white)` is a view modifier
        // (`_ForegroundStyleModifier`); the text's folds into the Text's run
        // attributes because `Text.font` keeps the receiver a `Text`, so the
        // `.foregroundStyle` resolves to Text's own (Text-returning) overload.
        // Read each accordingly.
        XCTAssertEqual(
            try hstack.image(0).foregroundStyleShapeStyle(Color.self),
            .white,
            "crop toggle icon must carry .foregroundStyle(.white) directly — a .bordered Button renders its label in the dark tint colour otherwise (#319)."
        )
        XCTAssertEqual(
            try hstack.text(1).attributes().foregroundColor(),
            .white,
            "crop toggle text must carry .foregroundStyle(.white) — see #74 for why the enclosing HStack's foreground does not propagate in live rendering."
        )
    }

    func test_aspect_ratio_picker_has_white_foreground() async throws {
        let view = try await makeCropActiveView()

        // cropSection (vStack 1) children: Text("Crop") 0, Picker 1, straighten VStack 2.
        let picker = try sidebarVStack(view).vStack(1).picker(1)

        XCTAssertEqual(
            try picker.foregroundStyleShapeStyle(Color.self),
            .white,
            "aspect-ratio Picker must carry .foregroundStyle(.white) — its menu-style selected-value label is near-black against the dark sidebar otherwise (#319)."
        )
    }
}
