import AppKit
import SwiftUI
@testable import UI
import TestSupport
import XCTest

final class RatingToastSnapshotTests: XCTestCase {
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

    private static let toastSize = CGSize(width: 300, height: 60)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    @MainActor
    private func renderFixedPixelImage(for view: some View) -> NSImage {
        let size = Self.toastSize
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

    /// Helper view that holds the toast state so we can render a
    /// `RatingToastView` with a specific rating without auto-dismiss.
    private struct ToastHost: View {
        @State var toast: LibraryViewModel.RatingToast?

        var body: some View {
            ZStack {
                Color(white: 0.08)
                RatingToastView(toast: $toast)
            }
        }
    }

    @MainActor
    func test_rating_toast_one_star() {
        let host = ToastHost(
            toast: .init(assetId: UUID(), rating: 1)
        )
        .frame(width: Self.toastSize.width, height: Self.toastSize.height)

        let image = renderFixedPixelImage(for: host)

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
    func test_rating_toast_three_stars() {
        let host = ToastHost(
            toast: .init(assetId: UUID(), rating: 3)
        )
        .frame(width: Self.toastSize.width, height: Self.toastSize.height)

        let image = renderFixedPixelImage(for: host)

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
    func test_rating_toast_five_stars() {
        let host = ToastHost(
            toast: .init(assetId: UUID(), rating: 5)
        )
        .frame(width: Self.toastSize.width, height: Self.toastSize.height)

        let image = renderFixedPixelImage(for: host)

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
