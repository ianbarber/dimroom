import Catalog
import Foundation
import Previews
import SwiftUI
import ViewInspector
import XCTest
@testable import UI

/// Structural regression guard for the segmented rating `Picker` inside
/// `LibraryView.filterBar`. The segmented style is backed by
/// `NSSegmentedControl`, which renders its segment labels in the default
/// (near-black) color and ignores `.foregroundStyle` applied to the inner
/// `Text` views — that is the residual black-on-dark-gray case described
/// in #241. The fix is `.colorScheme(.dark)` on the picker; this test
/// asserts the modifier remains attached so a future stylist can't drop
/// it silently. An `ImageRenderer`-based Layer B snapshot can't catch the
/// regression because `ImageRenderer` ignores `NSSegmentedControl`'s
/// AppKit rendering path entirely (it draws segment text via Core
/// Graphics in the default foreground). See #74 and #121 for the same
/// rendering-path-divergence rationale.
@MainActor
final class FilterBarStructureTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-filterbar-tests-\(UUID().uuidString)")
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

    private func makeView() throws -> LibraryView {
        let catalog = try CatalogDatabase.inMemory()
        let store = PreviewStore(cacheDirectory: tempCacheDir)
        let vm = LibraryViewModel(catalog: catalog, previewStore: store)
        return LibraryView(viewModel: vm)
    }

    func test_segmented_rating_picker_has_dark_color_scheme() throws {
        let view = try makeView()
        // body: VStack { filterBar; Group { … } }.background(…).overlay(…)…
        // filterBar children in order: ScopePicker, Divider, Text, Picker, Spacer, Button.
        let filterBar = try view.inspect().vStack().hStack(0)
        let picker = try filterBar.picker(3)

        let scheme = try picker.environment(\.colorScheme)
        XCTAssertEqual(
            scheme,
            .dark,
            "Segmented rating Picker must carry .colorScheme(.dark) — without it, NSSegmentedControl renders segment labels in default near-black against the dark filter bar (#241)."
        )
    }
}
