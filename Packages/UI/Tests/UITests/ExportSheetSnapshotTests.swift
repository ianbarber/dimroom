import AppKit
import EditEngine
import Foundation
import SwiftUI
@testable import UI
import TestSupport
import XCTest

final class ExportSheetSnapshotTests: XCTestCase {

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

    private static let sheetSize = CGSize(width: 500, height: 300)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    @MainActor
    private func renderFixedPixelImage(for view: some View, size: CGSize = sheetSize) -> NSImage {
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

    // MARK: - Export sheet default state

    @MainActor
    func test_export_sheet_default_state() async throws {
        let view = ExportSheetView(
            assetCount: 12,
            onExport: { _, _, _, _ in },
            onCancel: {}
        )

        let image = renderFixedPixelImage(for: view)

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

    // MARK: - Export sheet JPEG format (quality slider visible)

    @MainActor
    func test_export_sheet_jpeg_format() async throws {
        let view = ExportSheetView(
            assetCount: 12,
            initialFormat: .jpeg,
            onExport: { _, _, _, _ in },
            onCancel: {}
        )

        let image = renderFixedPixelImage(
            for: view,
            size: CGSize(width: 500, height: 340)
        )

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

    // MARK: - Export progress view

    @MainActor
    func test_export_progress_mid_export() async throws {
        let coordinator = ExportCoordinator()
        coordinator.setPhaseForTesting(.exporting)
        coordinator.setProgressForTesting(current: 5, total: 12)

        let image = renderFixedPixelImage(
            for: ExportProgressView(coordinator: coordinator),
            size: CGSize(width: 1024, height: 768)
        )

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

    // MARK: - Completion alert body

    /// Snapshots the composed alert body for a partial-success export
    /// via a plain `Text` wrapper. SwiftUI `.alert` modifiers aren't
    /// snapshot-friendly, so this locks in the copy that the App wraps
    /// in an alert payload.
    @MainActor
    func test_export_alert_with_skips() async throws {
        let message = ExportCompletionMessage.forCompletion(
            exported: 2,
            skipped: 1,
            failures: ["IMG_0003.jpg: no local copy available"]
        )
        let view = VStack(alignment: .leading, spacing: 6) {
            Text(message.title)
                .font(.headline)
            Text(message.body)
                .font(.body)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)

        let image = renderFixedPixelImage(
            for: view,
            size: CGSize(width: 360, height: 140)
        )

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
