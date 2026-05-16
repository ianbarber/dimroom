import AppKit
import Catalog
import EditEngine
import Foundation
import SnapshotTesting
import SwiftUI
@testable import UI
import XCTest

final class CurveEditorSnapshotTests: XCTestCase {

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

    private static let canvasSize = CGSize(width: 280, height: 320)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    @MainActor
    private func render(view: some View, size: CGSize = CurveEditorSnapshotTests.canvasSize) -> NSImage {
        let host = NSHostingView(rootView: AnyView(view.background(Color(white: 0.1))))
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
            fatalError("Failed to allocate NSBitmapImageRep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Snapshots

    @MainActor
    func test_curve_editor_identity() {
        let view = CurveEditorView(
            channel: .luminance,
            points: EditState.identityCurve,
            histogram: nil,
            onChange: { _ in },
            onReset: { }
        )
        .padding(8)

        let image = render(view: view)
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

    @MainActor
    func test_curve_editor_luminance_s_curve_with_histogram() {
        let sCurve: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.25, y: 0.10),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.90),
            CGPoint(x: 1, y: 1)
        ]
        let view = CurveEditorView(
            channel: .luminance,
            points: sCurve,
            histogram: Self.gradientHistogram(),
            onChange: { _ in },
            onReset: { }
        )
        .padding(8)

        let image = render(view: view)
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

    @MainActor
    func test_curve_editor_red_channel_no_histogram() {
        let liftRed: [CGPoint] = [
            CGPoint(x: 0, y: 0.05),
            CGPoint(x: 0.5, y: 0.6),
            CGPoint(x: 1, y: 1)
        ]
        // Histogram is provided but the editor must ignore it on non-luminance channels.
        let view = CurveEditorView(
            channel: .red,
            points: liftRed,
            histogram: Self.gradientHistogram(),
            onChange: { _ in },
            onReset: { }
        )
        .padding(8)

        let image = render(view: view)
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

    // MARK: - Helpers

    private static func gradientHistogram() -> HistogramData {
        let bins = 256
        var red = [Int](repeating: 0, count: bins)
        var green = [Int](repeating: 0, count: bins)
        var blue = [Int](repeating: 0, count: bins)
        var lum = [Int](repeating: 0, count: bins)
        for i in 0..<bins {
            let centre = 128.0
            let sigma = 40.0
            let d = (Double(i) - centre) / sigma
            let base = Int(1000.0 * exp(-0.5 * d * d))
            red[i] = base
            green[i] = Int(Double(base) * 0.9)
            blue[i] = Int(Double(base) * 0.8)
            lum[i] = (red[i] + green[i] + blue[i]) / 3
        }
        return HistogramData(
            red: red,
            green: green,
            blue: blue,
            luminance: lum,
            shadowClipping: .none,
            highlightClipping: .none,
            binCount: bins
        )
    }
}
