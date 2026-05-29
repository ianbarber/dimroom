import XCTest
import SwiftUI
import AppKit
@testable import UI

/// Layer A coverage for the two-axis VoiceOver wiring added in #343.
///
/// PR #342 exposed each wheel as a single adjustable element whose
/// increment/decrement moved hue only. The wheel is now an accessibility
/// container with two synthetic adjustable children — "<label> hue" and
/// "<label> saturation" — so a VoiceOver-only user can drive each axis.
///
/// These tests host the control in an on-screen window and walk the AppKit
/// accessibility tree the way VoiceOver would. SwiftUI only builds that tree
/// when the process is accessibility-active *and* the hosting view is in a
/// displayed window, so `setUp` activates the app and `makeHost` puts each
/// control in a real `NSWindow`. If the environment can't build the tree at all
/// (e.g. a headless CI box with no window server), the walk yields nothing and
/// the tests `XCTSkip` rather than report a false failure — the nudge math is
/// covered exhaustively in `ColorWheelKeyboardModelTests` and the saturation
/// path end-to-end in `bin/harness-develop-split-tone-keyboard-flow.sh`.
///
/// SwiftUI mirrors the hosted view into the window's accessibility tree more
/// than once, so the same logical element can appear multiple times; assertions
/// dedupe by accessibility label.
final class ColorWheelAccessibilityTests: XCTestCase {

    private var retainedWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    override func tearDown() {
        for window in retainedWindows { window.orderOut(nil) }
        retainedWindows.removeAll()
        super.tearDown()
    }

    // MARK: - Structure

    func test_exposesTwoAdjustableAxes_highlights() throws {
        try assertAdjustableAxes(label: "Highlights")
    }

    func test_exposesTwoAdjustableAxes_shadows() throws {
        try assertAdjustableAxes(label: "Shadows")
    }

    /// Each axis announces its own value, derived from the passed hue/saturation
    /// (saturation is on the 0...100 scale, matching the wheel's readout).
    func test_axesAnnounceTheirValues() throws {
        let elements = try hostedElements(label: "Highlights", hue: 40, saturation: 60)
        let hue = try XCTUnwrap(elements.first { axLabel($0) == "Highlights hue" })
        let saturation = try XCTUnwrap(elements.first { axLabel($0) == "Highlights saturation" })
        XCTAssertEqual(axValue(hue), "40°")
        XCTAssertEqual(axValue(saturation), "60")
    }

    /// The `color-wheel-<label>` identifier the harness/snapshot tests rely on
    /// still resolves after splitting the wheel into two children.
    func test_identifierStillResolves() throws {
        let elements = try hostedElements(label: "Shadows", hue: 220, saturation: 40)
        XCTAssertTrue(
            elements.contains { axIdentifier($0) == "color-wheel-shadows" },
            "expected the color-wheel-shadows identifier to still resolve"
        )
    }

    // MARK: - The saturation axis is now actually adjustable (the issue's core ask)

    func test_saturationIncrement_routesToOnSaturationChange() throws {
        var newSaturation: Double?
        var hueMoved = false
        let elements = try hostedElements(
            label: "Highlights", hue: 120, saturation: 50,
            onHueChange: { _ in hueMoved = true },
            onSaturationChange: { newSaturation = $0 }
        )
        let saturation = try XCTUnwrap(elements.first { axLabel($0) == "Highlights saturation" })

        axIncrement(saturation)

        XCTAssertEqual(try XCTUnwrap(newSaturation), 55, accuracy: 1e-9)
        XCTAssertFalse(hueMoved, "the saturation axis must not move hue")
    }

    func test_saturationDecrement_routesToOnSaturationChange() throws {
        var newSaturation: Double?
        let elements = try hostedElements(
            label: "Highlights", hue: 120, saturation: 50,
            onSaturationChange: { newSaturation = $0 }
        )
        let saturation = try XCTUnwrap(elements.first { axLabel($0) == "Highlights saturation" })

        axDecrement(saturation)

        XCTAssertEqual(try XCTUnwrap(newSaturation), 45, accuracy: 1e-9)
    }

    func test_hueIncrement_routesToOnHueChangeOnly() throws {
        var newHue: Double?
        var saturationMoved = false
        let elements = try hostedElements(
            label: "Highlights", hue: 120, saturation: 50,
            onHueChange: { newHue = $0 },
            onSaturationChange: { _ in saturationMoved = true }
        )
        let hue = try XCTUnwrap(elements.first { axLabel($0) == "Highlights hue" })

        axIncrement(hue)

        XCTAssertEqual(try XCTUnwrap(newHue), 125, accuracy: 1e-9)
        XCTAssertFalse(saturationMoved, "the hue axis must not move saturation")
    }

    // MARK: - Helpers

    private func assertAdjustableAxes(label: String) throws {
        let elements = try hostedElements(label: label, hue: 120, saturation: 50)
        let adjustableLabels = Set(elements.filter(axAdjustable).compactMap(axLabel))
        XCTAssertEqual(
            adjustableLabels,
            ["\(label) hue", "\(label) saturation"],
            "expected exactly the hue and saturation axes to be adjustable"
        )
    }

    /// Hosts the control in a displayed window and returns every accessibility
    /// element reachable from that window. Throws `XCTSkip` if the environment
    /// produced no tree at all.
    private func hostedElements(
        label: String,
        hue: Double,
        saturation: Double,
        onHueChange: @escaping (Double) -> Void = { _ in },
        onSaturationChange: @escaping (Double) -> Void = { _ in },
        onReset: @escaping () -> Void = { }
    ) throws -> [AnyObject] {
        let control = ColorWheelControl(
            label: label,
            hue: hue,
            saturation: saturation,
            onHueChange: onHueChange,
            onSaturationChange: onSaturationChange,
            onReset: onReset
        )
        let hosting = NSHostingView(rootView: control)
        hosting.frame = CGRect(x: 0, y: 0, width: 240, height: 200)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        retainedWindows.append(window)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        var collected: [AnyObject] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: AnyObject?, _ depth: Int) {
            guard depth < 16, let node, seen.insert(ObjectIdentifier(node)).inserted else { return }
            collected.append(node)
            for child in axChildren(node) { walk(child as AnyObject, depth + 1) }
        }
        walk(window, 0)

        if collected.count <= 1 {
            throw XCTSkip("AppKit accessibility tree unavailable in this environment")
        }
        return collected
    }

    // AppKit accessibility is reached through optional ObjC dispatch so the walk
    // works regardless of the concrete (private, SwiftUI-internal) element type.
    private func axChildren(_ o: AnyObject) -> [Any] {
        ((o.accessibilityChildren?()) ?? nil) ?? []
    }

    private func axLabel(_ o: AnyObject) -> String? {
        (o.accessibilityLabel?()) ?? nil
    }

    private func axValue(_ o: AnyObject) -> String? {
        // `accessibilityValue()` is declared (with differing return types) on
        // several AppKit role protocols, so AnyObject dispatch is ambiguous;
        // the value-bearing nodes are `NSAccessibilityElement`, which exposes a
        // single unambiguous `accessibilityValue() -> Any?`.
        (o as? NSAccessibilityElement)?.accessibilityValue() as? String
    }

    private func axIdentifier(_ o: AnyObject) -> String? {
        (o.accessibilityIdentifier?()) ?? nil
    }

    private func axAdjustable(_ o: AnyObject) -> Bool {
        (o.isAccessibilitySelectorAllowed?(#selector(NSAccessibilityProtocol.accessibilityPerformIncrement))) ?? false
    }

    private func axIncrement(_ o: AnyObject) {
        _ = o.accessibilityPerformIncrement?()
    }

    private func axDecrement(_ o: AnyObject) {
        _ = o.accessibilityPerformDecrement?()
    }
}
