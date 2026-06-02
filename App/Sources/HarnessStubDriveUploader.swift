import DriveClient
import Foundation

/// Harness-only `DriveUploading` stub injected by the
/// `--stub-drive-uploader` launch flag (#414). It exists so Layer C can
/// exercise the *full* post-import auto-upload branch (#270 AC1) — the
/// path that runs `UploadCoordinator.run(...)` and drives
/// `uploadCoordinatorPhase` to `done` — without real OAuth, network
/// traffic, or a configured `DriveClient`.
///
/// Minimal by design: it reports the asset's byte count as "uploaded"
/// once via `progress(...)` and returns `.uploaded(fileID:)`. It never
/// touches the network and never reads `ref.localPath` from disk —
/// `UploadCoordinator.run` only requires `asset.localPath` to be non-nil
/// (it constructs the `DriveAssetRef`); only the real `DriveUploader`
/// stats the file. A trivially-`Sendable` struct: no stored state, so no
/// lock is needed.
///
/// Deliberately not "recording": no acceptance criterion inspects the
/// stub's call count. If a future flow needs that, follow the
/// `OSAllocatedUnfairLock`-backed `RecordingUploader` pattern in
/// `App/Tests/AutoUploadAfterImportTests.swift`.
struct HarnessStubDriveUploader: DriveUploading {
    func upload(
        _ ref: DriveAssetRef,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> UploadOutcome {
        progress(ref.bytes, ref.bytes)
        return .uploaded(fileID: "harness-stub-\(ref.assetId.uuidString)")
    }
}
