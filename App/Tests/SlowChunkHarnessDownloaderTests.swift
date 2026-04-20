@testable import Dimroom
import Foundation
import XCTest

final class SlowChunkHarnessDownloaderTests: XCTestCase {
    func testEmitsMonotonicProgressEndingAtOne() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slow-chunks-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("payload.bin")
        let downloader = SlowChunkHarnessDownloader()
        let collector = TickCollector()

        try await downloader.download(
            driveFileId: "ignored",
            to: destination,
            progress: { @Sendable value in collector.append(value) }
        )

        let ticks = collector.values
        XCTAssertGreaterThanOrEqual(ticks.count, 5,
            "flow needs enough ticks for state-poll to land mid-stream")
        XCTAssertEqual(ticks.last, 1.0)
        for (a, b) in zip(ticks, ticks.dropFirst()) {
            XCTAssertLessThan(a, b, "progress must be strictly monotonic")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testProducesSamePayloadIrrespectiveOfDriveFileId() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slow-chunks-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = SlowChunkHarnessDownloader()
        let firstURL = dir.appendingPathComponent("a.bin")
        let secondURL = dir.appendingPathComponent("b.bin")

        try await downloader.download(driveFileId: "id-one", to: firstURL, progress: nil)
        try await downloader.download(driveFileId: "id-two", to: secondURL, progress: nil)

        let firstData = try Data(contentsOf: firstURL)
        let secondData = try Data(contentsOf: secondURL)
        XCTAssertEqual(firstData, secondData)
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
