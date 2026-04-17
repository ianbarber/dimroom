import AppKit
import CoreGraphics
@testable import AppIcon
import TestSupport
import XCTest

final class IconSnapshotTests: XCTestCase {

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

    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    private func renderToNSImage(pixelSize: Int) -> NSImage {
        let cgImage = AppIconRenderer.render(pixelSize: pixelSize)
        let size = NSSize(width: pixelSize, height: pixelSize)
        let nsImage = NSImage(cgImage: cgImage, size: size)
        return nsImage
    }

    func test_icon_128() {
        let image = renderToNSImage(pixelSize: 128)

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

    func test_icon_512() {
        let image = renderToNSImage(pixelSize: 512)

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
