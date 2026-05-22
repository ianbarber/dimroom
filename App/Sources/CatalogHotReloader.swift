import Catalog
import Foundation
import SyncEngine

/// Orchestrates an in-place catalog swap when the change poller reports a
/// remote `catalogChanged` outcome. Downloads the published catalog into
/// a sibling temp path, validates it opens as SQLite, atomically replaces
/// the local file, then opens and returns the new `CatalogDatabase`
/// stamped with the page token and `last_published_catalog_modified_time`
/// from the outcome so the next poll doesn't re-fire the same change.
///
/// Lives outside `AppDelegate` so the swap mechanics — pending-changes
/// re-check, atomic file move, retain-leak surface, sync-state stamping
/// — can be pinned by Layer A tests without standing up `NSApplication`.
enum CatalogHotReloader {

    /// Surfaces the path the orchestrator chose to abort. The AppDelegate
    /// maps `.pendingLocalChanges` to a `presentSyncConflictAlert` call
    /// so the user sees the same warning they would have if the poller
    /// had classified the change as a conflict in the first place.
    enum Outcome {
        case reloaded(CatalogDatabase)
        case pendingLocalChanges
    }

    /// Errors the swap raises. The temp-download path is wrapped in
    /// `downloadFailed`; validation errors come back as `validationFailed`;
    /// catalog-open / page-token writes as `openFailed`. The AppDelegate
    /// catches everything and falls back to the existing relaunch alert.
    enum ReloadError: Error, CustomStringConvertible {
        case downloadFailed(underlying: String)
        case validationFailed(underlying: String)
        case openFailed(underlying: String)
        case replaceFailed(underlying: String)

        var description: String {
            switch self {
            case .downloadFailed(let s): return "catalog download failed: \(s)"
            case .validationFailed(let s): return "downloaded catalog failed validation: \(s)"
            case .openFailed(let s): return "opening new catalog failed: \(s)"
            case .replaceFailed(let s): return "atomic replace failed: \(s)"
            }
        }
    }

    /// Run the swap. Caller side-effects (closing the old catalog,
    /// rebuilding view models / coordinator / publisher / poller, route
    /// reset) are intentionally left to the AppDelegate — this function
    /// only owns the file + new-catalog construction so the test surface
    /// stays bounded.
    ///
    ///   - `localPath` — on-disk catalog path to overwrite.
    ///   - `driveFileId` / `modifiedTime` / `pageToken` — values from
    ///     the `DeltaSyncOutcome.catalogChanged` triple. The new catalog
    ///     is stamped with `pageToken` + `modifiedTime` before being
    ///     returned so the next poll resumes from the correct cursor.
    ///   - `downloader` — `CatalogUploading.download` is the only
    ///     dependency we need from the uploader. Passing the protocol
    ///     keeps the test stub minimal.
    ///   - `hasPendingChanges` — re-asked at the moment of reload so a
    ///     user who kept editing between the alert appearing and clicking
    ///     "Reload Now" gets a conflict response instead of losing their
    ///     in-flight edits.
    static func reload(
        localPath: String,
        driveFileId: String,
        modifiedTime: String?,
        pageToken: String,
        downloader: any CatalogUploading,
        hasPendingChanges: () async -> Bool
    ) async throws -> Outcome {
        if await hasPendingChanges() {
            return .pendingLocalChanges
        }

        let tempPath = localPath + ".reload-tmp"
        // Defensive: a previous half-completed reload could have left the
        // temp path behind. Remove before downloading so the uploader
        // doesn't trip on an existing file.
        try? FileManager.default.removeItem(atPath: tempPath)

        do {
            _ = try await downloader.download(fileId: driveFileId, to: tempPath)
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ReloadError.downloadFailed(underlying: String(describing: error))
        }

        // Validate the temp file opens as SQLite before we let it
        // overwrite the live catalog. A corrupt download must not
        // clobber the user's local copy.
        do {
            let probe = try CatalogDatabase(path: tempPath)
            // Explicit no-op to keep the open in scope for the assertion;
            // the queue will be torn down at the end of this block.
            _ = probe
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ReloadError.validationFailed(underlying: String(describing: error))
        }

        // `FileManager.replaceItem` is the documented atomic-rename hop on
        // macOS. We can't use it directly because `replaceItemAt` requires
        // an existing destination; on first reload the destination is
        // already there (we wrote it at launch), but if a future caller
        // wires this up for a fresh-install path, `moveItem` is the
        // simpler fall-through.
        let src = URL(fileURLWithPath: tempPath)
        let dst = URL(fileURLWithPath: localPath)
        do {
            if FileManager.default.fileExists(atPath: localPath) {
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: src)
            } else {
                try FileManager.default.moveItem(at: src, to: dst)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ReloadError.replaceFailed(underlying: String(describing: error))
        }

        let newCatalog: CatalogDatabase
        do {
            newCatalog = try CatalogDatabase(path: localPath)
        } catch {
            throw ReloadError.openFailed(underlying: String(describing: error))
        }

        // Stamp the new sync state on the freshly-opened catalog so the
        // next `ChangePoller.pollOnce` resumes from the same page token
        // and treats the just-applied remote `modifiedTime` as the new
        // "last known published" baseline. Without this, the very next
        // poll would either re-fetch the change window or classify the
        // applied catalog as a conflict.
        do {
            try newCatalog.saveDrivePageToken(pageToken)
            if let modifiedTime {
                try newCatalog.saveLastPublishedCatalogModifiedTime(modifiedTime)
            }
        } catch {
            throw ReloadError.openFailed(underlying: String(describing: error))
        }

        return .reloaded(newCatalog)
    }
}
