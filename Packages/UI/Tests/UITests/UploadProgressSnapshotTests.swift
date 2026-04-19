import AppKit
import Foundation
import SwiftUI
@testable import UI
import TestSupport
import XCTest

final class UploadProgressSnapshotTests: XCTestCase {

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

    private static let frameSize = CGSize(width: 1024, height: 768)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

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
    func test_upload_progress_uploading_phase() async throws {
        let coordinator = UploadCoordinator()
        coordinator.setPhaseForTesting(.uploading)
        coordinator.setProgressForTesting(
            current: 1,
            total: 5,
            filename: "IMG_2037.CR3",
            currentBytes: 12_000_000,
            totalBytes: 24_000_000
        )

        let image = renderFixedPixelImage(
            for: UploadProgressView(coordinator: coordinator)
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

    @MainActor
    func test_upload_progress_done_phase() async throws {
        let coordinator = UploadCoordinator()
        coordinator.setPhaseForTesting(.done(uploadedCount: 3, skippedCount: 2))
        coordinator.setProgressForTesting(
            current: 5,
            total: 5,
            filename: "",
            currentBytes: 0,
            totalBytes: 0
        )

        let image = renderFixedPixelImage(
            for: UploadProgressView(coordinator: coordinator)
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

    @MainActor
    func test_upload_progress_failed_phase() async throws {
        let coordinator = UploadCoordinator()
        coordinator.setPhaseForTesting(.failed("retry budget exhausted"))
        coordinator.setProgressForTesting(
            current: 2,
            total: 5,
            filename: "IMG_0010.CR3",
            currentBytes: 0,
            totalBytes: 0
        )

        let image = renderFixedPixelImage(
            for: UploadProgressView(coordinator: coordinator)
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
