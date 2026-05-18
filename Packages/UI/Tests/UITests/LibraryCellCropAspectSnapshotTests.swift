import AppKit
import Catalog
import CoreGraphics
import Foundation
import SnapshotTesting
import SwiftUI
@testable import UI
import XCTest

/// Regression for issue #239 bug 4: the library grid must show the
/// crop's true aspect ratio rather than fill-cropping every thumbnail
/// into a square. The cell footprint stays square (so the grid layout
/// is unchanged), but a wide thumbnail letterboxes inside.
final class LibraryCellCropAspectSnapshotTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUp() async throws {
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-cell-aspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempCacheDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let dir = tempCacheDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempCacheDir = nil
    }

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

    @MainActor
    private func renderFixedPixelImage(
        for view: some View,
        size: CGSize
    ) -> NSImage {
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

    /// A landscape thumbnail must letterbox inside the square cell —
    /// dark cell background visible above and below the image rather
    /// than the image being cropped to a square.
    @MainActor
    func test_cell_letterboxes_landscape_thumbnail() throws {
        let asset = TestFixtures.makeAsset(hash: "wide-asset", filename: "wide.jpg")
        try TestFixtures.placeThumbnail(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 60, g: 180, b: 90),
            width: 256,
            height: 144
        )
        let row = LibraryRow(
            asset: asset,
            thumbnailURL: tempCacheDir
                .appendingPathComponent("wi", isDirectory: true)
                .appendingPathComponent("wide-asset.thumb.jpg"),
            previewURL: nil
        )

        let cell = LibraryCell(row: row, isSelected: false, rowVersion: 0)
            .frame(width: 200, height: 200)
            .background(Color(white: 0.05))

        let image = renderFixedPixelImage(
            for: cell,
            size: CGSize(width: 200, height: 200)
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

    /// A square thumbnail must still fill the entire cell with no
    /// letterbox bands.
    @MainActor
    func test_cell_fills_square_thumbnail() throws {
        let asset = TestFixtures.makeAsset(hash: "square-asset", filename: "square.jpg")
        try TestFixtures.placeThumbnail(
            for: asset,
            cacheDirectory: tempCacheDir,
            color: (r: 200, g: 80, b: 80),
            width: 256,
            height: 256
        )
        let row = LibraryRow(
            asset: asset,
            thumbnailURL: tempCacheDir
                .appendingPathComponent("sq", isDirectory: true)
                .appendingPathComponent("square-asset.thumb.jpg"),
            previewURL: nil
        )

        let cell = LibraryCell(row: row, isSelected: false, rowVersion: 0)
            .frame(width: 200, height: 200)
            .background(Color(white: 0.05))

        let image = renderFixedPixelImage(
            for: cell,
            size: CGSize(width: 200, height: 200)
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
