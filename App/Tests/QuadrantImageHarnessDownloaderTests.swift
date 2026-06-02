@testable import Dimroom
import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class QuadrantImageHarnessDownloaderTests: XCTestCase {
    func testWritesADecodableJPEGOfTheDeclaredSize() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quadrant-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("original.jpg")
        let downloader = QuadrantImageHarnessDownloader()
        let collector = TickCollector()

        try await downloader.download(
            driveFileId: "ignored",
            to: destination,
            progress: { @Sendable value in collector.append(value) }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
            "downloader must write a file at the destination")
        XCTAssertEqual(collector.values.last, 1.0,
            "downloader must report completion via progress(1.0)")

        // It must be a *real* image (the whole point — the sibling stubs write
        // garbage), decoding to the declared dimensions.
        let image = try decode(destination)
        XCTAssertEqual(image.width, QuadrantImageHarnessDownloader.payloadWidth)
        XCTAssertEqual(image.height, QuadrantImageHarnessDownloader.payloadHeight)
    }

    func testQuadrantCentresCarryTheFourDeclaredColours() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quadrant-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("original.jpg")
        try await QuadrantImageHarnessDownloader()
            .download(driveFileId: "ignored", to: destination, progress: nil)

        let image = try decode(destination)
        let pixels = try samplePixels(image, into: image.width, image.height)
        let w = image.width
        let h = image.height

        // Sample the four quadrant centres (¼/¾ along each axis).
        let sampled = [
            pixels.color(x: w / 4, y: h / 4, width: w),
            pixels.color(x: 3 * w / 4, y: h / 4, width: w),
            pixels.color(x: w / 4, y: 3 * h / 4, width: w),
            pixels.color(x: 3 * w / 4, y: 3 * h / 4, width: w),
        ]

        // Each declared colour must appear at exactly one quadrant centre,
        // proving four distinct flat regions (not garbage, not one flat fill).
        // We don't pin *which* centre carries *which* colour — that depends on
        // the bitmap's row order — only that the set matches.
        for declared in QuadrantImageHarnessDownloader.quadrantColors {
            let matches = sampled.filter { isClose($0, to: declared) }
            XCTAssertEqual(matches.count, 1,
                "declared colour \(declared) should appear at exactly one quadrant centre; sampled \(sampled)")
        }
    }

    func testProducesSamePayloadIrrespectiveOfDriveFileId() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quadrant-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = QuadrantImageHarnessDownloader()
        let firstURL = dir.appendingPathComponent("a.jpg")
        let secondURL = dir.appendingPathComponent("b.jpg")
        try await downloader.download(driveFileId: "id-one", to: firstURL, progress: nil)
        try await downloader.download(driveFileId: "id-two", to: secondURL, progress: nil)

        let firstData = try Data(contentsOf: firstURL)
        let secondData = try Data(contentsOf: secondURL)
        XCTAssertEqual(firstData, secondData,
            "payload must not depend on driveFileId")
    }

    // MARK: - Helpers

    private func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DecodeError.notDecodable
        }
        return image
    }

    /// Draw the decoded image into a known RGBA8 deviceRGB buffer so pixel
    /// reads are independent of the source's colour space / alpha layout.
    private func samplePixels(_ image: CGImage, into width: Int, _ height: Int) throws -> PixelBuffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw DecodeError.contextUnavailable }
        return PixelBuffer(bytes: bytes)
    }

    private func isClose(
        _ a: (r: UInt8, g: UInt8, b: UInt8),
        to b: (r: UInt8, g: UInt8, b: UInt8),
        tolerance: Int = 24
    ) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tolerance
            && abs(Int(a.g) - Int(b.g)) <= tolerance
            && abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    private enum DecodeError: Error {
        case notDecodable
        case contextUnavailable
    }
}

private struct PixelBuffer {
    let bytes: [UInt8]

    /// Read an RGB triple at (x, y). Buffer is RGBA8, row-major.
    func color(x: Int, y: Int, width: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2])
    }
}

private final class TickCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []

    func append(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }
}
