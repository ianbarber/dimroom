import DriveClient
import Foundation

/// Harness-only `DriveMarkerScanning` driven by a JSON fixture on disk.
/// Production never sees this — the App gates it on
/// `DIMROOM_HARNESS_DRIVE_BACKFILL_FIXTURE=<path>`. Lets Layer C exercise
/// the real `DriveMarkerBackfill` skip/patch logic without faking Drive's
/// HTTP transport.
///
/// Fixture format:
/// ```
/// {
///   "files": [
///     { "id": "untagged-id", "name": "DSC_0001.jpg", "mimeType": "image/jpeg" },
///     { "id": "tagged-id", "name": "DSC_0002.jpg", "mimeType": "image/jpeg",
///       "appProperties": {"dimroom": "1"} }
///   ]
/// }
/// ```
///
/// The fixture is loaded once into an in-memory snapshot. `patchMarker`
/// stamps the marker onto the matching entry, so a second backfill run in
/// the same session sees the file already tagged (idempotency holds).
final class HarnessStubMarkerScanner: DriveMarkerScanning, @unchecked Sendable {
    struct FixtureFile: Codable {
        var id: String
        var name: String?
        var mimeType: String?
        var appProperties: [String: String]?
    }

    struct Fixture: Codable {
        var files: [FixtureFile]
    }

    private let lock = NSLock()
    private let fixturePath: String
    private var files: [DriveFilesAPI.DriveFile]?

    init(fixturePath: String) {
        self.fixturePath = fixturePath
    }

    func listAllFiles() async throws -> [DriveFilesAPI.DriveFile] {
        try loadIfNeeded()
        return lock.withLock { files ?? [] }
    }

    func patchMarker(fileId: String) async throws {
        try loadIfNeeded()
        lock.withLock {
            guard var current = files else { return }
            guard let index = current.firstIndex(where: { $0.id == fileId }) else { return }
            let existing = current[index]
            var props = existing.appProperties ?? [:]
            props[DriveAppProperties.dimroomMarkerKey] = DriveAppProperties.dimroomMarkerValue
            current[index] = DriveFilesAPI.DriveFile(
                id: existing.id,
                name: existing.name,
                mimeType: existing.mimeType,
                appProperties: props
            )
            files = current
        }
    }

    private func loadIfNeeded() throws {
        let alreadyLoaded = lock.withLock { files != nil }
        if alreadyLoaded { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let mapped = fixture.files.map { file in
            DriveFilesAPI.DriveFile(
                id: file.id,
                name: file.name,
                mimeType: file.mimeType,
                appProperties: file.appProperties
            )
        }
        lock.withLock {
            if files == nil { files = mapped }
        }
    }
}
