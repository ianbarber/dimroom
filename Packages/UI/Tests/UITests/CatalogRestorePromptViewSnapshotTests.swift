import AppKit
import Foundation
import SwiftUI
@testable import UI
import TestSupport
import XCTest

/// Layer B snapshot coverage for the catalog-restore prompt. Pinned
/// dates and sizes keep the rendered text deterministic across CI/local
/// runs. Four variants exercise the photo-count present/absent split
/// (the appProperties round-trip on legacy catalogs) and the connect
/// + failure styles.
final class CatalogRestorePromptViewSnapshotTests: XCTestCase {
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

    private static let frameSize = CGSize(width: 420, height: 180)
    private static let snapshotPrecision: Float = 0.99
    private static let snapshotPerceptualPrecision: Float = 0.98

    private static let fixedModifiedTime = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_500_000)

    @MainActor
    private func renderFixedPixelImage(for view: some View) -> NSImage {
        let size = Self.frameSize
        let host = NSHostingView(rootView: AnyView(
            ZStack {
                Color(white: 0.98)
                view
                    .padding(16)
            }
            .frame(width: size.width, height: size.height)
        ))
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
    func test_restore_existing_with_photo_count() {
        let view = CatalogRestorePromptView(
            style: .restoreExisting(
                photoCount: 1284,
                sizeBytes: 4_194_304,
                modifiedTime: Self.fixedModifiedTime
            ),
            now: Self.fixedNow
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

    @MainActor
    func test_restore_existing_without_photo_count() {
        // Legacy catalogs lack `appProperties.dimroom_photo_count`. The
        // prompt body must drop the photo-count fragment instead of
        // showing "nil photos".
        let view = CatalogRestorePromptView(
            style: .restoreExisting(
                photoCount: nil,
                sizeBytes: 2_097_152,
                modifiedTime: Self.fixedModifiedTime
            ),
            now: Self.fixedNow
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

    @MainActor
    func test_offer_connect() {
        let view = CatalogRestorePromptView(
            style: .offerConnect,
            now: Self.fixedNow
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

    @MainActor
    func test_restore_failed() {
        let view = CatalogRestorePromptView(
            style: .restoreFailed(
                reason: "Server returned status 503"
            ),
            now: Self.fixedNow
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

    // MARK: - Body text (logic test, no UI)

    func testRestoreExistingBodyOmitsCountWhenNil() {
        let body = CatalogRestorePromptView.restoreExistingBody(
            photoCount: nil,
            sizeBytes: 1_048_576,
            modifiedTime: nil,
            now: Self.fixedNow
        )
        XCTAssertFalse(body.contains("photo"), body)
        XCTAssertTrue(body.contains("1.0 MB"), body)
    }

    func testRestoreExistingBodyIncludesPluralisedCount() {
        let body = CatalogRestorePromptView.restoreExistingBody(
            photoCount: 1,
            sizeBytes: 1_048_576,
            modifiedTime: nil,
            now: Self.fixedNow
        )
        XCTAssertTrue(body.contains("1 photo"), body)
        XCTAssertFalse(body.contains("1 photos"), body)
    }

    func testRestoreExistingBodyIncludesDateFragmentWhenPresent() {
        let body = CatalogRestorePromptView.restoreExistingBody(
            photoCount: 2,
            sizeBytes: 1_048_576,
            modifiedTime: Self.fixedModifiedTime,
            now: Self.fixedNow
        )
        XCTAssertTrue(body.contains("last updated"), body)
    }

    func testRestoreFailedBodyOmitsReasonWhenBlank() {
        let body = CatalogRestorePromptView.restoreFailedBody(reason: "   ")
        XCTAssertFalse(body.contains("  "), "expected single-space body: \(body)")
        XCTAssertTrue(body.contains("empty catalog"), body)
    }
}
