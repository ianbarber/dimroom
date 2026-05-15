@testable import Dimroom
import Foundation
import XCTest

final class HoldUntilReleasedHarnessDownloaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Each test starts from an empty coordinator. The downloader is
        // process-scoped so a stale entry from a prior test could leak.
        HoldUntilReleasedHarnessDownloader.shared.release()
    }

    func testDownloadDoesNotReturnUntilRelease() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("payload.bin")
        let downloader = HoldUntilReleasedHarnessDownloader()
        let completion = CompletionFlag()

        let task = Task {
            try await downloader.download(driveFileId: "ignored", to: destination, progress: nil)
            completion.fire()
        }

        // Give the parked task a chance to register its continuation.
        try await waitForPendingCount(equals: 1)
        XCTAssertFalse(completion.didFire, "download must not return before release()")

        HoldUntilReleasedHarnessDownloader.shared.release()
        try await task.value
        XCTAssertTrue(completion.didFire)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testReleaseFansOutToEveryPendingCaller() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = HoldUntilReleasedHarnessDownloader()
        let tasks = (0..<3).map { idx in
            Task {
                let url = dir.appendingPathComponent("p-\(idx).bin")
                try await downloader.download(driveFileId: "id-\(idx)", to: url, progress: nil)
            }
        }

        try await waitForPendingCount(equals: 3)
        HoldUntilReleasedHarnessDownloader.shared.release()

        for task in tasks {
            try await task.value
        }
        XCTAssertEqual(HoldUntilReleasedHarnessDownloader.shared.pendingCount, 0)
    }

    func testCancellationWhileHeldThrowsAndUnregisters() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = HoldUntilReleasedHarnessDownloader()
        let task = Task {
            try await downloader.download(
                driveFileId: "ignored",
                to: dir.appendingPathComponent("p.bin"),
                progress: nil
            )
        }

        try await waitForPendingCount(equals: 1)
        task.cancel()

        do {
            try await task.value
            XCTFail("cancelled download should throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        // The cancelled slot should be removed from the map so a later
        // release() doesn't try to resume a now-defunct continuation.
        XCTAssertEqual(HoldUntilReleasedHarnessDownloader.shared.pendingCount, 0)
        // And a no-op release on an empty map must not crash.
        HoldUntilReleasedHarnessDownloader.shared.release()
    }

    func testReleaseWithNoPendingCallsIsNoOp() {
        XCTAssertEqual(HoldUntilReleasedHarnessDownloader.shared.pendingCount, 0)
        HoldUntilReleasedHarnessDownloader.shared.release()
        XCTAssertEqual(HoldUntilReleasedHarnessDownloader.shared.pendingCount, 0)
    }

    // MARK: - Helpers

    /// Polls `pendingCount` for up to 2 s. Avoids hard `Task.sleep`
    /// races between the test driver and the task we just spawned.
    private func waitForPendingCount(equals expected: Int) async throws {
        for _ in 0..<200 {
            if HoldUntilReleasedHarnessDownloader.shared.pendingCount == expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for pendingCount == \(expected); got \(HoldUntilReleasedHarnessDownloader.shared.pendingCount)")
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() { lock.lock(); fired = true; lock.unlock() }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}
