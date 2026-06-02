@testable import Dimroom
import DriveClient
import Foundation
import XCTest

/// Layer A coverage for #414 — the `--stub-drive-uploader` harness flag
/// and the no-network `DriveUploading` stub it injects. The flag lets a
/// Layer C flow drive the *full* post-import auto-upload branch (#270 AC1)
/// without real OAuth or network traffic. These tests pin the predicate
/// that recognises the flag and prove the stub has no disk/network
/// dependency.
final class HarnessStubDriveUploaderTests: XCTestCase {
    // MARK: - shouldStubDriveUploader

    func testStubFlagFalseWhenAbsent() {
        XCTAssertFalse(AppDelegate.shouldStubDriveUploader(args: []))
    }

    func testStubFlagFalseForHarnessAlone() {
        XCTAssertFalse(AppDelegate.shouldStubDriveUploader(
            args: ["--harness", "--fixture-catalog", "/tmp/x.sqlite"]
        ))
    }

    func testStubFlagTrueWhenPresent() {
        XCTAssertTrue(AppDelegate.shouldStubDriveUploader(
            args: ["--harness", "--stub-drive-uploader"]
        ))
    }

    // MARK: - HarnessStubDriveUploader.upload

    /// The stub must return `.uploaded(fileID:)` even for a ref pointing at
    /// a path that does not exist on disk — proving it never stats the file
    /// or hits the network (the real `DriveUploader` would throw
    /// `missingLocalFile`). The returned id is namespaced by asset UUID.
    func testUploadReturnsUploadedWithoutTouchingDisk() async throws {
        let uploader = HarnessStubDriveUploader()
        let assetId = UUID()
        let ref = DriveAssetRef(
            assetId: assetId,
            localPath: URL(fileURLWithPath: "/nonexistent/harness/IMG_0001.jpg"),
            contentHash: "deadbeef",
            originalFilename: "IMG_0001.jpg",
            bytes: 4096,
            captureDate: nil,
            importedDate: Date(timeIntervalSince1970: 0),
            sourceType: .digital,
            mimeType: "image/jpeg"
        )

        let outcome = try await uploader.upload(ref) { _, _ in }

        XCTAssertEqual(outcome, .uploaded(fileID: "harness-stub-\(assetId.uuidString)"))
    }

    /// The single progress callback reports the full byte count so the
    /// upload UI's progress surface still moves under the stub.
    func testUploadReportsProgressOnce() async throws {
        let uploader = HarnessStubDriveUploader()
        let recorded = ProgressRecorder()
        let ref = DriveAssetRef(
            assetId: UUID(),
            localPath: URL(fileURLWithPath: "/nonexistent/harness/IMG_0002.jpg"),
            contentHash: "feedface",
            originalFilename: "IMG_0002.jpg",
            bytes: 2048,
            captureDate: nil,
            importedDate: Date(timeIntervalSince1970: 0),
            sourceType: .digital,
            mimeType: "image/jpeg"
        )

        _ = try await uploader.upload(ref) { sent, total in
            recorded.record(sent: sent, total: total)
        }

        XCTAssertEqual(recorded.calls, [Progress(sent: 2048, total: 2048)])
    }
}

private struct Progress: Equatable {
    var sent: Int64
    var total: Int64
}

/// Thread-safe sink for the `@Sendable` progress callback.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Progress] = []

    var calls: [Progress] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func record(sent: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Progress(sent: sent, total: total))
    }
}
