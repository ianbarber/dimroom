import Catalog
import DriveClient
import Foundation
import UI

/// Decision helper that auto-uploads freshly-imported originals to Drive
/// when the user has opted in (Settings → Drive → "Auto-upload originals
/// after import", `SettingsStore.driveAutoUploadOriginals`).
///
/// Both import paths — `AppDelegate.importFolderFromMenu` (GUI) and
/// `HarnessController.handleImportFolder` (harness) — call this after a
/// successful import so they traverse one code path. The shared
/// `UploadCoordinator` is already observed by the upload UI, so progress
/// surfaces with no new view work.
///
/// The trigger is silent (no prompt) but visible (existing upload
/// progress reflects it). It never shows an alert on failure — unlike the
/// manual `uploadSelectedToDriveFromMenu` path, the spec requires
/// auto-upload to stay quiet; `UploadCoordinator.phase` already conveys
/// the outcome. If any precondition is unmet the helper returns silently
/// and the next manual upload picks the assets up.
@MainActor
enum AutoUploadAfterImport {
    static func runIfEnabled(
        sessionId: UUID,
        settingsStore: SettingsStore,
        driveAuthState: DriveAuthState,
        driveUploader: (any DriveUploading)?,
        uploadCoordinator: UploadCoordinator,
        catalog: CatalogDatabase
    ) async {
        // 1. Opt-in gate.
        guard settingsStore.driveAutoUploadOriginals else { return }

        // 2. Drive must be connected. Silent no-op otherwise — the next
        //    manual upload picks the assets up.
        guard driveAuthState.status.isConnected else { return }

        // 3. A real uploader must be configured (nil until Drive connects;
        //    always nil in harness mode). Silent no-op.
        guard let driveUploader else { return }

        // 4. Don't re-enter a running upload — `UploadCoordinator.run`
        //    mutates published state and is not safely reentrant. A manual
        //    or prior auto-upload already in flight wins; the user can
        //    re-trigger.
        guard !uploadCoordinator.isActive else { return }

        // 5. Fetch just the assets from this import session. An empty
        //    session (nothing new imported) means nothing to upload.
        let assets = (try? catalog.fetchAssets(filter: AssetFilter(importSessionId: sessionId))) ?? []
        guard !assets.isEmpty else { return }

        // 6. Run. No alert on `.failed` — the upload UI conveys outcome.
        await uploadCoordinator.run(assets: assets, catalog: catalog, uploader: driveUploader)
    }
}
