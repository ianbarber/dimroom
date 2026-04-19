import SwiftUI
import ViewInspector
import XCTest
@testable import UI

/// Structural regression guard for the `ScopePicker` `Menu` label. The
/// Layer B snapshot (`LibrarySnapshotTests.test_scope_picker_with_three_sessions`)
/// cannot catch `.foregroundStyle` regressions here because
/// `ImageRenderer` propagates foreground style from an `HStack` container
/// to its children, while live `Menu` + `.menuStyle(.borderlessButton)`
/// rendering does not — so a pre-fix HStack-level `.foregroundStyle` and
/// the post-fix per-child placement produce visually identical PNGs. See
/// issues #74 and #121.
@MainActor
final class ScopePickerStructureTests: XCTestCase {
    private func makePicker() -> ScopePicker {
        let binding = Binding<LibraryViewModel.Scope>(
            get: { .all },
            set: { _ in }
        )
        return ScopePicker(sessions: [], selectedScope: binding)
    }

    func test_menu_label_hstack_has_no_foreground_style() throws {
        let hstack = try makePicker().inspect().menu().labelView().hStack()

        // Regression signature: pre-fix code applied
        // `.foregroundStyle(Color(white: 0.7))` to the enclosing HStack.
        // Live Menu rendering ignored it, producing black-on-dark-gray.
        // Assertion: the HStack must NOT carry a foregroundStyle modifier.
        XCTAssertThrowsError(
            try hstack.foregroundStyleShapeStyle(Color.self),
            "HStack must not carry .foregroundStyle — it does not propagate into a Menu label's subtree in live rendering; apply it per-child instead."
        )
    }

    func test_menu_label_image_has_foreground_style_directly() throws {
        let hstack = try makePicker().inspect().menu().labelView().hStack()
        let image = try hstack.image(0)

        XCTAssertNoThrow(
            try image.foregroundStyleShapeStyle(Color.self),
            "Image child must carry its own .foregroundStyle — the enclosing HStack's does not propagate inside a Menu label."
        )
    }

    func test_menu_label_text_has_foreground_style_directly() throws {
        let hstack = try makePicker().inspect().menu().labelView().hStack()
        let text = try hstack.text(1)

        XCTAssertNoThrow(
            try text.foregroundStyleShapeStyle(Color.self),
            "Text child must carry its own .foregroundStyle — the enclosing HStack's does not propagate inside a Menu label."
        )
    }
}
