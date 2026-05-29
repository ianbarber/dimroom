import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
@testable import UI
import XCTest

/// Pins the Split Toning section's two `ColorWheelControl`s as they
/// render in the Develop sidebar. Renders the wheels standalone (not
/// inside the full `DevelopView`) because the sidebar `ScrollView`
/// starts at the top and Split Toning sits below the fold at the
/// existing fixed snapshot size — so the full-view snapshot in
/// `DevelopSnapshotTests.test_develop_split_toning` doesn't actually
/// capture the wheel pixels. This focused snapshot does.
final class ColorWheelControlSnapshotTests: XCTestCase {
    private static let snapshotRecordMode: SnapshotTestingConfiguration.Record? = {
        if ProcessInfo.processInfo.environment["DIMROOM_RECORD_SNAPSHOTS"] == "1" {
            return .all
        }
        return nil
    }()

    private func runAssertSnapshot(_ body: () -> Void) {
        if let recordMode = Self.snapshotRecordMode {
            withSnapshotTesting(record: recordMode) {
                body()
            }
        } else {
            body()
        }
    }

    @MainActor
    private func renderFixedPixelImage(for view: some View, size: CGSize) -> NSImage {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            fatalError("Failed to allocate NSBitmapImageRep for snapshot")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Both Split Toning wheels rendered with the same orange/teal
    /// values the existing `test_develop_split_toning` test drives —
    /// Highlights at hue 30°/sat 50, Shadows at hue 210°/sat 50.
    @MainActor
    func test_split_toning_wheels() throws {
        let panel = VStack(alignment: .leading, spacing: 6) {
            Text("Split Toning")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .textCase(.uppercase)
            ColorWheelControl(
                label: "Highlights",
                hue: 30,
                saturation: 50,
                onHueChange: { _ in },
                onSaturationChange: { _ in },
                onReset: { }
            )
            ColorWheelControl(
                label: "Shadows",
                hue: 210,
                saturation: 50,
                onHueChange: { _ in },
                onSaturationChange: { _ in },
                onReset: { }
            )
        }
        .padding(12)
        .frame(width: 256)
        .background(Color(white: 0.1))

        let image = renderFixedPixelImage(
            for: panel,
            size: CGSize(width: 280, height: 360)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(precision: 0.99, perceptualPrecision: 0.98)
            )
        }
    }

    /// Highlights wheel holding keyboard focus (#305) — pins the accent
    /// focus ring drawn around the focused wheel. Uses
    /// `focusedAppearanceOverride` because an offscreen `NSHostingView`
    /// can't drive `@FocusState`. Shadows is left unfocused so the diff
    /// between the two is what the ring contributes.
    @MainActor
    func test_split_toning_wheels_focused_highlights() throws {
        let panel = VStack(alignment: .leading, spacing: 6) {
            Text("Split Toning")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .textCase(.uppercase)
            ColorWheelControl(
                label: "Highlights",
                hue: 30,
                saturation: 50,
                onHueChange: { _ in },
                onSaturationChange: { _ in },
                onReset: { },
                focusedAppearanceOverride: true
            )
            ColorWheelControl(
                label: "Shadows",
                hue: 210,
                saturation: 50,
                onHueChange: { _ in },
                onSaturationChange: { _ in },
                onReset: { }
            )
        }
        .padding(12)
        .frame(width: 256)
        .background(Color(white: 0.1))

        let image = renderFixedPixelImage(
            for: panel,
            size: CGSize(width: 280, height: 360)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(precision: 0.99, perceptualPrecision: 0.98)
            )
        }
    }

    /// Both wheels at identity (hue=0, sat=0). Pins the empty-state
    /// indicator-at-centre rendering.
    @MainActor
    func test_split_toning_wheels_identity() throws {
        let panel = VStack(alignment: .leading, spacing: 6) {
            ColorWheelControl(
                label: "Highlights",
                hue: 0,
                saturation: 0,
                onHueChange: { _ in },
                onSaturationChange: { _ in },
                onReset: { }
            )
            ColorWheelControl(
                label: "Shadows",
                hue: 0,
                saturation: 0,
                onHueChange: { _ in },
                onSaturationChange: { _ in },
                onReset: { }
            )
        }
        .padding(12)
        .frame(width: 256)
        .background(Color(white: 0.1))

        let image = renderFixedPixelImage(
            for: panel,
            size: CGSize(width: 280, height: 360)
        )

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(precision: 0.99, perceptualPrecision: 0.98)
            )
        }
    }
}
