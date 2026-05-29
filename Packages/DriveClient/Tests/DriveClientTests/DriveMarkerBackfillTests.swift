import XCTest
@testable import DriveClient

final class DriveMarkerBackfillTests: XCTestCase {

    /// In-memory `DriveMarkerScanning` fake. Records every `patchMarker`
    /// call and reflects the marker back into its file list so a second
    /// run sees the once-untagged file as tagged (idempotency).
    private actor FakeScanner: DriveMarkerScanning {
        private var files: [DriveFilesAPI.DriveFile]
        private(set) var patchedIds: [String] = []

        init(files: [DriveFilesAPI.DriveFile]) {
            self.files = files
        }

        func listAllFiles() async throws -> [DriveFilesAPI.DriveFile] {
            files
        }

        func patchMarker(fileId: String) async throws {
            patchedIds.append(fileId)
            guard let index = files.firstIndex(where: { $0.id == fileId }) else { return }
            let existing = files[index]
            var props = existing.appProperties ?? [:]
            props[DriveAppProperties.dimroomMarkerKey] = DriveAppProperties.dimroomMarkerValue
            files[index] = DriveFilesAPI.DriveFile(
                id: existing.id,
                name: existing.name,
                mimeType: existing.mimeType,
                appProperties: props
            )
        }
    }

    private let tagged = DriveFilesAPI.DriveFile(
        id: "tagged",
        name: "DSC_0002.jpg",
        mimeType: "image/jpeg",
        appProperties: ["dimroom": "1"]
    )
    private let untagged = DriveFilesAPI.DriveFile(
        id: "untagged",
        name: "DSC_0001.jpg",
        mimeType: "image/jpeg",
        appProperties: nil
    )

    private func makeBackfill(scanner: FakeScanner) -> DriveMarkerBackfill {
        // Zero throttle so the test doesn't actually sleep between PATCHes.
        DriveMarkerBackfill(scanner: scanner, throttle: .zero)
    }

    func testPatchesMissingMarkerAndSkipsPresent() async throws {
        let scanner = FakeScanner(files: [untagged, tagged])
        let backfill = makeBackfill(scanner: scanner)

        let summary = try await backfill.run()

        XCTAssertEqual(summary, BackfillSummary(scanned: 2, patched: 1, skipped: 1))
        let patched = await scanner.patchedIds
        XCTAssertEqual(patched, ["untagged"])
    }

    func testSecondRunIsIdempotent() async throws {
        let scanner = FakeScanner(files: [untagged, tagged])
        let backfill = makeBackfill(scanner: scanner)

        _ = try await backfill.run()
        let second = try await backfill.run()

        // The first run tagged `untagged`; the second finds both tagged.
        XCTAssertEqual(second, BackfillSummary(scanned: 2, patched: 0, skipped: 2))
        let patched = await scanner.patchedIds
        XCTAssertEqual(patched, ["untagged"], "second run must not re-patch")
    }

    func testNeverPatchesFolders() async throws {
        let folder = DriveFilesAPI.DriveFile(
            id: "folder",
            name: "2024",
            mimeType: DriveFilesAPI.folderMimeType,
            appProperties: nil
        )
        let scanner = FakeScanner(files: [folder, untagged])
        let backfill = makeBackfill(scanner: scanner)

        let summary = try await backfill.run()

        // Folder excluded from the scanned tally and never patched.
        XCTAssertEqual(summary, BackfillSummary(scanned: 1, patched: 1, skipped: 0))
        let patched = await scanner.patchedIds
        XCTAssertEqual(patched, ["untagged"])
        XCTAssertFalse(patched.contains("folder"))
    }
}
