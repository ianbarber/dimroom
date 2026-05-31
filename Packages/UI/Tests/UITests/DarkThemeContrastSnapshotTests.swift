import AppKit
import Foundation
import SwiftUI
@testable import UI
import TestSupport
import XCTest

/// Layer B coverage for the dark-theme control convention (#326): a
/// representative `Picker`, `Menu`, and `Button` rendered on the app's
/// dark library background (`Color(white: 0.08)`) with `.darkThemeControl()`
/// (pickers / menu) and per-child `.foregroundStyle(.white)` (button)
/// applied, exactly as the real surfaces use them.
///
/// IMPORTANT — read before trusting this test: this snapshot **cannot**
/// catch the dark-on-dark regression it depicts. The bug lives in the live
/// AppKit drawing of `NSSegmentedControl` / `NSPopUpButton`, which an
/// offline `cacheDisplay`/`ImageRenderer` capture renders differently from
/// the running app — a regressed (modifier-dropped) segmented picker
/// snapshots identically to a fixed one. The load-bearing regression guard
/// is `DarkThemeControlStructureTests` (Layer A) plus the harness
/// screenshots (Layer C). This snapshot exists to satisfy the issue's
/// acceptance criterion literally and to guard the surrounding chrome /
/// layout, not the contrast itself. See `FilterBarStructureTests` and
/// `ScopePickerStructureTests` for the full rationale.
final class DarkThemeContrastSnapshotTests: XCTestCase {
    /// Running with `DIMROOM_RECORD_SNAPSHOTS=1` records fresh goldens
    /// instead of asserting (see `LibrarySnapshotTests` for why goldens are
    /// regenerated on a CI-equivalent runner rather than per dev machine).
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

    private static let frameSize = CGSize(width: 320, height: 220)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    /// Renders the view to a fixed-pixel `NSImage` so output is identical
    /// regardless of the runner's backing scale factor (same approach as
    /// `LibrarySnapshotTests.renderFixedPixelImage`).
    @MainActor
    private func renderFixedPixelImage(for view: some View) -> NSImage {
        let size = Self.frameSize
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

    @MainActor
    func test_dark_theme_controls_render_light_on_dark() async throws {
        let image = renderFixedPixelImage(for: DarkThemeControlGallery())

        runAssertSnapshot {
            assertSnapshot(
                of: image,
                as: .image(
                    precision: Self.snapshotPrecision,
                    perceptualPrecision: Self.snapshotPerceptualPrecision
                )
            )
        }
    }
}

/// Mirror of the real call sites: a segmented `Picker` and a borderless
/// `Menu` under `.darkThemeControl()`, and a `.bordered` `Button` whose
/// label children carry explicit `.foregroundStyle(.white)` (the lever the
/// shared modifier can't provide for a custom-tinted bordered button).
private struct DarkThemeControlGallery: View {
    var body: some View {
        VStack(spacing: 16) {
            Picker("Rating", selection: .constant(1)) {
                Text("All").tag(0)
                ForEach(1...5, id: \.self) { n in
                    Text("\(n)★").tag(n)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .darkThemeControl()

            Menu {
                Button("All Photos") {}
                Button("Recently Deleted") {}
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tray.2")
                        .foregroundStyle(Color(white: 0.7))
                    Text("All Photos")
                        .foregroundStyle(Color(white: 0.7))
                }
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .darkThemeControl()
            .fixedSize()

            Button {
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "crop.rotate")
                        .foregroundStyle(.white)
                    Text("Crop")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(Color(white: 0.3))
        }
        .padding(24)
        .frame(width: 320, height: 220)
        .background(Color(white: 0.08))
    }
}
