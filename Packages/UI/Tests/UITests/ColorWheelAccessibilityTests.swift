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
/// **These tests skip under a plain `swift test` / CI.** SwiftUI only
/// materialises its AppKit accessibility representation when a real assistive
/// client (VoiceOver) is attached to the process; a headless test run — even
/// with the app activated and a key window on screen — never builds the
/// synthetic children or the `color-wheel-<label>` identifier. So each test
/// hosts the control, walks the tree, and `XCTSkip`s when that tree did not
/// materialise (detected by the absence of the labelled axes *and* the
/// identifier — not merely a small node count, which the degraded window +
/// hosting-view chrome would otherwise satisfy). When run under VoiceOver (or
/// an Xcode UI-test host) the tree is present and the assertions execute for
/// real.
///
/// The always-on automated coverage for this feature is therefore:
/// `ColorWheelKeyboardModelTests` (the shared nudge math these axes route
/// through) and the Layer C `bin/harness-develop-split-tone-keyboard-flow.sh`
/// flow. This suite is the structural check that the accessibility tree is
/// wired the way VoiceOver expects, exercised on a manual VoiceOver pass.
///
/// SwiftUI mirrors the hosted view into the window's accessibility tree more
/// than once, so the same logical element can appear multiple times; lookups
/// match on accessibility label and dedupe by object identity.
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

    /// Both axes exist and each one is independently adjustable. `axAdjustable`
    /// is only ever asked of the axis-labelled elements — the bare `NSWindow`
    /// and hosting view also report `accessibilityPerformIncrement` as allowed,
    /// so an unfiltered scan would mistake container chrome for an axis.
    private func assertAdjustableAxes(label: String) throws {
        let elements = try hostedElements(label: label, hue: 120, saturation: 50)
        for axisLabel in ["\(label) hue", "\(label) saturation"] {
            let axis = try XCTUnwrap(
                elements.first { axLabel($0) == axisLabel },
                "missing the \(axisLabel) accessibility axis"
            )
            XCTAssertTrue(
                axAdjustable(axis),
                "the \(axisLabel) axis should expose an adjustable action"
            )
        }
    }

    /// Hosts the control in a displayed window and returns every accessibility
    /// element reachable from that window.
    ///
    /// Throws `XCTSkip` when the SwiftUI accessibility tree did not materialise
    /// (the headless `swift test` case). The signal is concrete: we require the
    /// two labelled axes the control adds, or its `color-wheel-<label>`
    /// identifier, to actually be present. A bare node-count check is not
    /// enough — the degraded tree still carries the window + hosting-view +
    /// reparenting-proxy nodes, none of which are the elements under test.
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

        let hasBothAxes = collected.contains { axLabel($0) == "\(label) hue" }
            && collected.contains { axLabel($0) == "\(label) saturation" }
        let hasIdentifier = collected.contains {
            axIdentifier($0) == "color-wheel-\(label.lowercased())"
        }
        guard hasBothAxes || hasIdentifier else {
            throw XCTSkip(
                "SwiftUI accessibility tree not materialised under headless swift test "
                + "(no assistive client attached). The hue/saturation axes and the "
                + "color-wheel-\(label.lowercased()) identifier are only built when "
                + "VoiceOver is running; run this suite under VoiceOver to exercise it. "
                + "The nudge math is covered by ColorWheelKeyboardModelTests and the "
                + "Layer C split-tone harness flow."
            )
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
