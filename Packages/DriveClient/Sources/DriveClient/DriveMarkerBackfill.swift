import Foundation

/// Transport the marker backfill walks over. Splits the "find every file
/// under `/PhotoTool/`" + "stamp one file" pair out of the backfill logic
/// so tests can drive the skip/patch decisions without faking Drive's HTTP
/// shape. Mirrors the `DriveChangesFetching` split used by the change
/// poller. The live implementation is `DriveMarkerScanner`.
public protocol DriveMarkerScanning: Sendable {
    /// Every file under the `/PhotoTool/` root. The live scanner recurses
    /// into subfolders; folder entries may still be returned, so the
    /// backfill skips them by mimeType rather than trusting the scanner.
    func listAllFiles() async throws -> [DriveFilesAPI.DriveFile]
    /// PATCH the dimroom marker onto a single file by id.
    func patchMarker(fileId: String) async throws
}

/// Tally returned by a backfill run. `scanned` counts the non-folder files
/// the run considered; `patched` got the marker added; `skipped` already
/// carried it.
public struct BackfillSummary: Sendable, Equatable {
    public let scanned: Int
    public let patched: Int
    public let skipped: Int

    public init(scanned: Int, patched: Int, skipped: Int) {
        self.scanned = scanned
        self.patched = patched
        self.skipped = skipped
    }
}

/// One-shot, idempotent backfill of the shared `appProperties.dimroom`
/// marker onto every legacy file under `/PhotoTool/` (#328). Files
/// uploaded before #310 don't carry the marker, so the change poller's
/// scope filter would silently drop them; this walks the tree and PATCHes
/// the ones that are missing it, leaving already-tagged files untouched.
///
/// Throttled: a configurable delay is awaited between PATCHes so a large
/// library doesn't burst Drive's write quota. Tests inject a zero delay.
public actor DriveMarkerBackfill {
    private let scanner: any DriveMarkerScanning
    private let throttle: Duration
    private let clock: any Clock<Duration>

    public init(
        scanner: any DriveMarkerScanning,
        throttle: Duration = .milliseconds(200),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.scanner = scanner
        self.throttle = throttle
        self.clock = clock
    }

    /// Walks every file under `/PhotoTool/`, PATCHing the marker onto any
    /// that lack it. Idempotent: a second run over the now-tagged set
    /// patches nothing.
    public func run() async throws -> BackfillSummary {
        let files = try await scanner.listAllFiles()
        var scanned = 0
        var patched = 0
        var skipped = 0
        for file in files {
            // Never tag folders, even if the scanner surfaces one.
            if file.mimeType == DriveFilesAPI.folderMimeType { continue }
            scanned += 1
            if file.appProperties?[DriveAppProperties.dimroomMarkerKey]
                == DriveAppProperties.dimroomMarkerValue {
                skipped += 1
                continue
            }
            // Throttle between writes (not before the first one).
            if patched > 0 {
                try await clock.sleep(for: throttle)
            }
            try await scanner.patchMarker(fileId: file.id)
            patched += 1
        }
        return BackfillSummary(scanned: scanned, patched: patched, skipped: skipped)
    }
}
